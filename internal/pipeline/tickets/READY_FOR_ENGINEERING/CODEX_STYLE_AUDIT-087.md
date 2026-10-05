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
