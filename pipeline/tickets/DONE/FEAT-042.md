---
id: FEAT-042
type: feature
severity: medium
source: architecture discussion 2026-09-09 (workspace direction review)
---

**Depends on:** BUG-020 (proving the path is only meaningful once the generated Ingress has working TLS).

Make the outside-the-cluster → service path (Ingress → Service → pod) exercisable in local dev, and decide how the production hostname is created, so north-south routing is tested rather than assumed.

## Problem

- `sol dev up` installs Redpanda, PostgreSQL, Loki, Grafana, Alloy, Tempo, and Prometheus, but no ingress controller and no cert-manager (see the golden-path CI job's install list and `cli/platform/local/`). `sol up` still renders an Ingress for every `-svc` (`cli/sol/lib/sol_cli_deployment_render.ml:220`), so locally that object is inert and developers reach services only through `kubectl port-forward`.
- This contradicts the "Dev mirrors prod exactly" principle (`docs/architecture/PRODUCT_ARCHITECTURE.md:39`): the production traffic entry path is never exercised locally.
- There is no external-dns anywhere in the repo; the AWS/GCP modules create a DNS zone but nothing creates the record for an app's `ingress_host`, so shipping a public hostname is currently an undocumented manual step.

## Goal

A developer (and CI) can send a request through the same Ingress → Service → pod path production uses, locally; and the production DNS/hostname story is either automated or documented end to end.

## Remediation

- Install ingress-nginx in `sol dev up` (NodePort, matching `platform/infra/base`'s `ingress_service_type` variable) or add a `sol dev ingress` subcommand.
- Add an e2e/golden-path assertion that a request through the local ingress reaches a deployed `/health`.
- Decide DNS: add external-dns to `platform/infra/base`, or document the exact manual Route53/Cloud DNS record creation and which value `ingress_host` must match. Update TUTORIAL/README either way.
- Keep real certs optional locally (localhost/self-signed); the check is routing, not certificate issuance.

## Acceptance criteria

- After `sol dev up` + `sol up`, a request to the local ingress address reaches the service without a manual `kubectl port-forward`.
- An automated check covers the ingress path.
- Docs state exactly how the production hostname record is created.

## Completion notes

Chose the "install in `sol dev up`" option over a separate `sol dev ingress`
subcommand: `cmd_dev.ml` now installs the same ingress-nginx chart and version
as `cli/platform/infra/base` (NodePort, matching the documented k3d/local
`ingress_service_type`) and port-forwards the controller to
`http://localhost:8088`. 8088 is deliberate: `sol up` already forwards the
first service on 8080, so reusing that would collide.

Rendering fix found while wiring this up: k3s/k3d ships Traefik as its own
IngressClass, so a classless Ingress was claimed locally by Traefik (and, with
`watch-ingress-without-class` false and no default class, ignored by
ingress-nginx entirely). `ingress_doc` now emits `ingressClassName: nginx`,
matching `base`'s existing `ingress_class_name = "nginx"`; this is what makes
the generated Ingress deterministic on both local and cloud clusters. Unit
assertions cover both the hostless and `ingress_host` cases.

DNS: chose to document the manual record rather than add external-dns, since
nothing yet proves the extra controller is warranted. `docs/guides/TUTORIAL.md`
and `docs/deployment/self-hosted-substrate-contract.md` now state exactly how
to point an `ingress_host` at the controller (`route53_zone_id` /
`route53_nameservers` outputs, wildcard option, cert-manager only completing
TLS once the name resolves).

Validation: `dune build`, `dune test cli/sol/test/` (49 tests), `dune fmt
--preview`, and `devtools/ci/check_platform_component_drift.sh` all pass. The
golden-path smoke now curls `http://localhost:8088/health` after `sol up` and
fails if the Ingress never routes. Confirmed the runtime path live against a
local k3d cluster: installed the chart exactly as `cmd_dev.ml` does, applied a
hostless `ingressClassName: nginx` Ingress to an existing sol-deployed
`charge-svc`, and got HTTP 200 (and Prometheus text on `/metrics`) through the
port-forwarded controller. Live cloud DNS/TLS is not exercised here.

