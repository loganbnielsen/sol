---
id: CODEX_STYLE_AUDIT-087
type: bug
severity: high
title: "Supervise required TypeScript relay and job runner failures with the application"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Supervise required TypeScript relay and job runner failures with the application

**Depends on:** None.

**Principles:** 6, 18, 20–24, 29, 31, 32, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `examples/pluto/app/demo_ts/order_svc/src/index.ts:239`: runRelay's returned error is logged inside `.then`, producing a fulfilled Promise<void>.
- `examples/pluto/app/demo_ts/fulfillment_worker/src/index.ts:227`: the relay repeats that pattern.
- `:250`: the jobs runner repeats it; lifecycle drain later awaits promises whose failures have already been erased.

## Mechanism and impact

A required runner can permanently terminate while the HTTP service keeps accepting orders or the worker keeps processing transactions. Durable intents accumulate without their owned executor. Returning-error promises are converted into successful child completion, so the parent cannot report truthful health or coordinate shutdown.

## Remediation

Observe terminal runner outcomes through the owning service/worker lifecycle. A required child failure must stop new work, lower readiness where available, trigger bounded cleanup, and become a non-success application outcome retaining the cause. Preserve normal abort semantics; do not replace this with an unobserved rejected promise or ad-hoc restart loop.

## Acceptance criteria

- Inject relay failure in both service and worker and jobs failure in worker; verify new work stops and all remaining resources close.
- Preserve the original runner cause and report a non-success parent outcome.
- Distinguish normal requested shutdown from failure without unhandled rejection or duplicate reporting.
- Cover failure before lifecycle registration and failure after startup.

- Demo/example: update runnable TypeScript service/worker lifecycle wiring and demonstrate terminal runner handling.
- Language parity: compare required-child supervision with the OCaml reference behavior and record the explicit verdict.

## Existing work and scope

The three swallowed child outcomes share a lifecycle root cause and belong in one ticket. No open matching ticket was found. This can be implemented for configured runners independently of the required-storage ticket.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.

## Completion notes (2026-10-05)

**Premise re-verified at pickup** on `origin/main`: `order_svc/src/index.ts` and
`fulfillment_worker/src/index.ts` both ended their `runRelay` chains with
`.then((error) => { if (error) console.error(...) })`, and the worker did the same for `runJobs`,
turning a returned `RunError` into a fulfilled `Promise<void>` and erasing it before the drain
awaited it.

**Fix.** Each unit has `src/runner-supervision.ts`: `supervise(post)` records the first terminal
runner failure, reports it once, and calls the owning lifecycle's `shutdown()`; a failure that
arrives before `attach(lifecycle)` still triggers shutdown when the lifecycle is registered; a
second runner failure neither replaces the cause nor shuts down twice. `watch(running, label,
supervisor)` adapts a `Promise<RunError | undefined>` (a clean stop resolves `undefined`). Both
units pass their relays and the worker's job runner through `watch`, and each adds a final shutdown
hook that rethrows the recorded cause so `runService`/`runWorker` report a non-success outcome
(exit 1) after every real cleanup hook has run. The service's `isReady()` therefore flips to false
for `/readyz`, and its drain `app.close()`s to stop new work; the worker's drain aborts both
runners and disconnects the consumer.

**Tests.** `test/supervision.test.ts` drives both units' helpers: a first failure shuts down once
and keeps its cause, a second failure does not shut down again or change the cause, a failure
before registration shuts down once attached, a clean stop is not a failure, and `watch` reports
only a terminal error. `npm run build -w order-svc -w fulfillment-worker` typechecks and the
demo's `npm test` passes.

**Demo/example.** The runnable `demo_ts` service and worker are the example and now supervise
their runners; no application-author-facing contract changed.

**Language parity (DEC-022).** The OCaml reference app owns its relay/jobs fibers under the
service/worker lifecycle; this restores the explicit TS equivalent and is recorded as
already-equivalent for required-child supervision.

**Limitations.** The tests exercise the supervision policy and lifecycle signalling, not a real
SIGTERM against a live broker; the lifecycle library's exit-code path is its own contract.
