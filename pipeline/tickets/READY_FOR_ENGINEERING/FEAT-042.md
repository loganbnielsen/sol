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
