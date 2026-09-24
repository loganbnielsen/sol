---
id: FEAT-096
type: feature
severity: medium
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

TypeScript services need a readiness endpoint that turns unready on shutdown, as OCaml `-svc` now has

**Depends on:** None.

**Finding:** FND-0041 (c) (`internal/pipeline/audits/findings/`). Parity tracking from INFRA-073 (DEC-022).

## Problem

INFRA-073 gives OCaml `-svc` a `/readyz` that turns 503 when shutdown begins, while the
listener keeps serving for `shutdown_delay_s` (part A), and points their `readinessProbe`
at it (part B). `@sol-fab/svc` (npm, 0.1.0) does not own routing, and the TS demo's `order_svc` serves
only `/healthz`. So INFRA-073 part B keeps TypeScript services (sol.yml
`language: typescript`) on `/healthz` readiness, and they still stop accepting before
Kubernetes removes their endpoint.

## Decision Required

Where the TS readiness endpoint lives: in `@sol-fab/svc` (the lifecycle it already
installs knows when shutdown begins), or in each app, documented. The first matches
the OCaml contract.

## Remediation

Per the decision: serve `/readyz` (503 once shutdown begins, then a delay before the
server closes) in `@sol-fab/svc`, update `examples/pluto/app/demo_ts`, then drop the
TypeScript exception in `Sol_cli_deployment_render` (the `readiness_path` match) and its
render test.

## Acceptance criteria

- A TS `-svc` pod's readiness turns 503 on SIGTERM before its listener closes.
- Rendered TS `-svc` manifests use `/readyz`.
- Demo/example: `demo_ts/order_svc` updated.
