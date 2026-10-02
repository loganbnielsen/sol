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

## Decision (2026-10-02)

**The readiness state machine lives in `@sol-fab/svc`; the route is mounted by the
app.** `@sol-fab/svc` deliberately does not own routing, so it cannot register an
HTTP route itself without coupling to Fastify/Express. Instead the lifecycle
owns readiness — `runService` marks the service unready when shutdown begins,
keeps serving for `shutdownDelayMs` (matching OCaml's `shutdown_delay_s`, default
5000 ms), and only then drains — and exposes `isReady()` (plus a
`readinessHandler`-shaped helper) for the app's `GET /readyz`. This matches the
OCaml contract: the framework owns shutdown, the app exposes the endpoint the
generated manifest probes.

## Remediation

Per the decision: give `runService` a bounded `shutdownDelayMs` and a readiness
state in `@sol-fab/svc`; have `examples/pluto/app/demo_ts/order_svc` serve
`/readyz` from it; then drop the TypeScript exception in
`Sol_cli_deployment_render` (the `readiness_path` match) and its render test.

## Acceptance criteria

- A TS `-svc` pod's readiness turns 503 on SIGTERM before its listener closes.
- Rendered TS `-svc` manifests use `/readyz`.
- Demo/example: `demo_ts/order_svc` updated.

## Premise check (2026-10-02)

Verified at `sol-typescript@a858953`: `packages/svc/src/index.ts` had no
`shutdownDelayMs` and `ServiceLifecycle` had no `isReady`. Premise held.

## Done (2026-10-02)

**What landed.**

- `loganbnielsen/sol-typescript#5` (merged `a21bd72`) adds the readiness contract
  to `runService`: `shutdownDelayMs` (default 5000, `sol-svc`'s
  `shutdown_delay_s`) and `isReady()`, flipped false synchronously when shutdown
  begins and before the delay and the drain. Released as `@sol-fab/svc@0.2.0`
  (tag `svc-v0.2.0`) over OIDC trusted publishing, with provenance.
- `Sol_cli_deployment_render`'s `readiness_path` now maps **both** declared
  languages to `/readyz`; an undeclared language still stays on `/healthz` (it is
  unknown, never assumed OCaml — DEC-022 §7). `test_manifest_render`'s
  TypeScript case was inverted to match.
- `examples/pluto/app/demo_ts/order_svc` mounts `GET /readyz` on the lifecycle's
  `isReady()` and returns 503 once shutdown begins, keeps `GET /healthz`, and
  moves its pin to `@sol-fab/svc@^0.2.0` (lockfile regenerated).

**Checks run.** `dune build` clean; `dune test cli/test/` green (54 + 8 tests,
including the inverted TypeScript readiness assertion). Demo
`npm run build -w order-svc -w fulfillment-worker` clean against the published
`0.2.0`. CI's `golden-path-smoke-ts` exercises the rendered `/readyz` probe
end to end.

**Demo/example coverage.** `demo_ts/order_svc` is the example update.

**Language parity.** The readiness row is now aligned: a TypeScript `-svc` and an
OCaml `-svc` present the same `/readyz` contract to the same probe, and
`docs/deployment/workload-availability.md` states it.

**Note on the earlier blocker.** The blocked-on gate this ticket briefly carried
was wrong: `npm trust list` showed `@sol-fab/svc` and `@sol-fab/worker` already
had trusted publishers for `loganbnielsen/sol-typescript` + `release.yml`. The
`release.yml` comment claiming the trust was still pending is stale and should be
corrected.


