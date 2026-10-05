---
id: FEAT-135
type: feature
severity: low
title: "Give the TypeScript framework an operation-retry helper with the shared policy vocabulary"
source: FEAT-114 (the OCaml operation-retry helper) on 2026-10-03 — the TS verdict was deliberately deferred, this ticket is the tracked gap
---

**Depends on:** None.

FEAT-114 landed `sol-retry` for OCaml: one bounded, jittered, non-blocking helper over a
`(unit -> ('a, 'e) result)`-shaped operation, with the policy vocabulary
`base_delay_s`, `max_delay_s`, `max_attempts`, `jitter_ratio` that `sol-jobs` and the
worker retry machinery share. `internal/specs/framework-conventions.md` records the
per-language verdict for that row as **deliberately deferred, tracked by this ticket**
(DEC-022: silence is not a verdict).

The TypeScript framework has no equivalent. `@sol-fab/*` ships the Kafka retry relay and
the DLQ routing, but nothing that retries a dependency call in place, so a TS `-svc`,
`-worker` or `-fn` that must survive a transient Postgres/HTTP failure either hand-rolls a
loop per call site or gives up — the exact gap FEAT-114 closed on the OCaml side.

## Trigger

A TypeScript reference-application path needs to retry a dependency call in place — most
immediately FEAT-133 (the TypeScript half of the 'Pluto orders' reference application),
which mirrors the OCaml `notify_worker` that FEAT-114 made retry its transaction. If
FEAT-133 reaches for a retry loop of its own instead, that is this ticket being due.

## Remediation (proposed, for triage)

- A `@sol-fab/*` helper with the same four-field policy vocabulary and the same semantics:
  bounded (`max_attempts`, negative = unbounded, zero refused), jittered and capped, `await`
  between attempts rather than a blocking sleep, exhaustion returns the last error to the
  caller, and cancellation (`AbortSignal`) propagates instead of finishing the budget.
- Retry the operation, never the message or the handler — a TS worker's outcome vocabulary
  is `Ack | Fail` for the same reason the OCaml one is.
- Mirror FEAT-114's cases: success after retry, exhaustion returning the last error,
  cancellation, jitter bounds, and validation refusals.
- Record the verdict as **implemented** in the operation-level-retry row of
  `internal/specs/framework-conventions.md`, and update the
  `internal/specs/typescript-capability-inventory.md` inventory so the two
  agree.

## Acceptance criteria

- One shared public helper, documented as operation-level, with the message-level
  alternative explicitly rejected.
- The policy vocabulary and defaults match `Sol_retry.default_policy`.
- Tests cover success after retry, exhaustion, cancellation and jitter bounds.
- A TypeScript example or demo path retries an operation in place, and the conventions row
  says `implemented`.

**Demo/example coverage:** the TypeScript reference application (`examples/pluto/app/demo_ts`)
is the natural home once the trigger fires; the ticket that implements this updates it in
the same pass.

**TypeScript parity (DEC-022):** this ticket *is* the parity work for FEAT-114's row.
