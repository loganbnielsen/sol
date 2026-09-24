---
id: INFRA-073
type: bug
severity: medium
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

`-svc` graceful shutdown: fail readiness and delay listener close so rolling deploys do not refuse requests

**Depends on:** None.

**Finding:** FND-0041 (`internal/pipeline/audits/findings/`).

**Premise verified 2026-09-23** against `origin/main @ f3e9480b` while filing (see the finding).

## Problem

On SIGTERM `sol-svc` stops accepting immediately while Kubernetes removes the endpoint asynchronously; manifests have no `preStop`, and `/healthz` serves readiness and never turns unready during drain.

## Remediation

Add a readiness endpoint (`/readyz`) that returns 503 once shutdown begins; on SIGTERM flip readiness, keep serving for a short configurable delay (default ~5s, below `terminationGracePeriodSeconds`), then stop accepting and drain. Render `readinessProbe` against `/readyz` for `Http_service`.

## Acceptance criteria

- Test: after stop, `/readyz` is 503 while requests still succeed during the delay.
- Rendered `-svc` manifest uses `/readyz` for readiness (render test).
- Demo/example: generated svc manifests change — note in completion notes.
- TS parity: record verdict for the TS svc.

## Progress

- **Part A (framework):** `sol-svc` serves `/readyz` (200, then 503 once a stop
  begins), and `?shutdown_delay_s` (default 5s) keeps the listener serving after readiness
  flips, with the drain deadline measured after the delay. The manifests are unchanged
  in part A, because generated workspaces and the pluto images install `sol-svc` from
  `main`: switching the probe in the same PR would have CI deploy a `main`-built service
  (no `/readyz` yet) against a `/readyz` probe.
- **Part B (manifests), after A is on `main`:** `-svc` `readinessProbe` → `/readyz` for
  OCaml; TypeScript services stay on `/healthz` (their framework serves no `/readyz`),
  tracked as FEAT-096. Then the ticket moves to DONE.

## Completion notes (2026-09-24)

- **Part B, done:** the `-svc` Deployment renders `readinessProbe` against `/readyz`
  for OCaml services (`?readiness_path`, chosen from the spec's `language`). Liveness
  and startup stay on `/healthz`. A TypeScript `-svc` keeps `/healthz` for readiness
  until its framework serves `/readyz` (FEAT-096). Render tests cover both. Mutation
  check (built, failed the intended test): an OCaml service rendered with `/healthz`.
- Timing: the worst-case shutdown (5 s delay plus the 30 s drain) stays under the
  rendered `terminationGracePeriodSeconds: 45`.
- **Demo/example:** generated `-svc` manifests change (readiness path). The commented
  probe in `cli/platform/local/k8s/svc-template.yaml` now points at `/readyz`. Since
  BUG-048's CI change, the golden-path smoke builds the scaffolded workspace against
  this commit's `sol-svc`, so the smoke deploys a service that serves `/readyz` behind
  a `/readyz` probe.
- **Language parity:** TypeScript stays on `/healthz`; FEAT-096 (BACKLOG) records
  what its framework needs.

**CI round (2026-09-24):** golden-path-smoke-ts failed. The TypeScript `order_svc`
deployed by `sol up` was probed on `/readyz` and got 404. `sol up` builds its plan
without the resolved `sol.yml`, so every service's language is `None` there, and part
B had treated `None` as OCaml. It is now fail-safe: only a service that *declares*
`language: ocaml` gets `/readyz`; an undeclared language is unknown and stays on
`/healthz`, which every framework serves (DEC-022 §7: language is never inferred). New
render test "undeclared language stays on /healthz", with a mutation check (`None →
/readyz` fails it). The `sol up`/`sol deploy` divergence is filed as BUG-056.
Consequence: scaffolded OCaml services (whose `sol.yml` declares no language) and
anything deployed by `sol up` keep `/healthz` for readiness until they declare
`language: ocaml` / BUG-056 lands. Part A's shutdown delay still applies to them.
