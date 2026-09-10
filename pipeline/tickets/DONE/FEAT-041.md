---
id: FEAT-041
type: feature
severity: high
source: architecture discussion 2026-09-09 (workspace direction review)
---

**Depends on:** None.

Let a workspace declare that one service calls another, and have Sol wire the address, the network path, and the internal-auth credentials so a cross-domain synchronous call works in dev and in production without hand-written YAML.

## Problem

Sol already renders almost everything needed for service-to-service calls, but the pieces are not connected, so `charge_svc` (namespace `acme-payments`) cannot call `checkout_svc` (namespace `acme-checkout`) out of the box:

- Each `-svc` renders a ClusterIP `Service` on port 80 → targetPort 8080 (`cli/sol/lib/sol_cli_manifest_yaml.ml:692`), so `http://checkout-svc.<workspace>-<domain>.svc.cluster.local` resolves. Namespace is `<workspace>-<domain>` (`cli/sol/lib/sol_cli_deployment_plan.ml:309`), i.e. one namespace per domain.
- Only platform dependencies are injected into the ConfigMap (`default_cluster_env`: Kafka, schema registry, Postgres, Loki, Pushgateway, Tempo — `cli/sol/lib/sol_cli_manifest_yaml.ml:41`). No peer service URL is ever wired, and app code has no typed way to ask for one.
- The generated NetworkPolicy allows ingress only from pods in the same namespace plus the `ingress-nginx` and `monitoring` namespaces, and egress only to DNS plus `redpanda`/`postgresql`/`monitoring` (`cli/sol/lib/sol_cli_manifest_yaml.ml:742-784`). A cross-domain call is therefore blocked in both directions. `[service] env` can point at a peer, but the policy still drops the traffic.
- The internal-auth half already exists: a route can declare the `Api_key` auth level (`framework/sol-svc/lib/auth.ml:32`) validated against `SOL_API_KEY`/`SOL_API_KEY_FILE` (`framework/sol-svc/lib/service.ml:228`).
- There is no outbound HTTP client helper in the framework; callers must hand-roll `cohttp-eio` and remember the API-key header and trace propagation.

ROADMAP lists "service discovery and env wiring" as Sol's responsibility (`docs/planning/ROADMAP.md:139`), so this is a hole in an already-committed product boundary rather than a new direction.

## Goal

A workspace author declares a dependency edge; Sol resolves it into an address, opens exactly that network path, and supplies the credentials. Nothing about Kubernetes namespaces, DNS, or NetworkPolicy appears in application code.

## Remediation

- Add a typed declaration to `sol.toml`, e.g. `[service] calls = ["checkout/checkout_svc"]`, parsed in `cli/sol/lib/sol_cli_toml.ml` and carried on the deployment plan (`cli/sol/lib/sol_cli_deployment_plan.ml`).
- Resolve each declared target to `http://<name>.<workspace>-<domain>.svc.cluster.local` and inject it into the caller's ConfigMap (e.g. `CHECKOUT_SVC_URL`). Keep DNS/namespace knowledge in the render layer; app code reads an env var.
- Extend `network_policy_doc` so a declared edge adds egress from the caller namespace to the target namespace on 8080 plus the matching ingress rule — per declared pair only, never a blanket namespace open.
- Wire the `Api_key` secret to the caller when the target route declares the `Api_key` auth level (shared secret or explicit reference), and document the `SOL_API_KEY*` contract.
- Add a small outbound client helper (or document the `cohttp-eio` pattern) that sets the API-key header and forwards `traceparent` so a request keeps its trace across the hop.
- Document events as the default integration for cross-domain flows; a synchronous call is an explicit, declared opt-in (fits "explicit over implicit").

## Acceptance criteria

- A workspace with a declared `calls` edge renders the caller's ConfigMap URL env var and a NetworkPolicy that admits exactly that pair in both namespaces.
- An undeclared peer is still denied by the default NetworkPolicy.
- The golden-path smoke job (or a new e2e check) has one `-svc` synchronously call another across namespaces and asserts a 200.
- The HTTP hop appears as a connected span in Tempo when tracing is enabled.

## Completion notes

Adds `[service] calls = ["domain/service_name"]` to `sol.toml`, resolved in the
deployment plan into a `service_call` (`env_var`, `url`, target namespace/name).
The caller's ConfigMap gets `<SERVICE>_URL`, the generated NetworkPolicy is
widened only for each declared pair (egress on the caller, ingress on the
target via a computed reverse edge), and `SOL_API_KEY` is emitted in the
generated Secret so `Api_key` routes share one internal key. Declaring an
unknown/mistyped target, a non-`-svc` target, or a `calls` name that collides
with an `[infra.env]` key is a plan error.

The golden-path smoke now scaffolds a throwaway peer (`sol new svc
checkout/checkout`), declares `calls` on charge_svc, and after deploy runs two
throwaway curl pods in the caller namespace: one labelled `app=charge-svc`
(must reach the peer's `/healthz`) and one unlabelled (must be denied by the
target's NetworkPolicy). The generated runtime image has no curl, hence the
probe pods.

Validation: `dune build`, `dune test cli/sol/test/` (49 tests), `dune fmt
--preview`, plus a local `sol up --dry-run` on a scaffolded two-service
workspace — `CHECKOUT_SVC_URL` present, 22 rendered docs parse, and the
NetworkPolicies show exactly `payments/charge-svc -> checkout/checkout-svc:8080`
(caller egress) and the matching reverse ingress. Live-cluster enforcement is
left to the CI job, which cannot be run here.

Trace continuity is documented rather than asserted: the ticket's remediation
allowed either a client helper or documenting the pattern, and the smoke's
cross-namespace request is made by a probe pod, not instrumented app code, so
there is no span to check. The runtime contract now documents forwarding the
current `traceparent` (`Obs_trace.inject_to_headers` from
`Sol_obs.current_trace_context`), which `Sol_svc` extracts into
`Request.trace_ctx` on the callee side. A first-class client helper with
automatic propagation remains a possible follow-up.

