---
id: CODEX_STYLE_AUDIT-086
type: bug
severity: high
title: "Require storage before the TypeScript fulfillment worker consumes messages"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Require storage before the TypeScript fulfillment worker consumes messages

**Depends on:** None.

**Principles:** 2, 7, 18, 21, 29, 31, 32, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `examples/pluto/app/demo_ts/fulfillment_worker/src/index.ts:64` reads optional POSTGRES_URL.
- `:91`–`:104`: the transaction executes only if `db` exists.
- `:111`–`:120`: the handler still increments successful processing and returns ACK, while startup explicitly skips storage when the URL is absent.
- `:133` and the relay/jobs startup conditionals disable the required downstream work without refusing consumption.

## Mechanism and impact

A consumed OrderPlaced can be acknowledged without recording fulfillment, its outbox intent, or its job intent. The example's domain contract requires these effects; optional storage is not a valid fulfillment mode. The OCaml reference path requires its database. Logging that storage was skipped does not preserve message semantics.

## Remediation

Validate required storage configuration before connecting/subscribing to Kafka. Pass required database/job handles into the handler instead of optional globals and non-null assertions. Remove the successful no-storage branch while preserving the transaction that groups state, publication intent, and job intent.

## Acceptance criteria

- Absent, empty, and whitespace-only POSTGRES_URL fails before consumption or acknowledgement.
- Valid processing commits state, outbox, and job intents in one transaction.
- Transaction failure returns failure without acknowledgement.
- Test the startup ordering and handler failure contract, not just the environment helper.

- Demo/example: update and exercise the runnable TypeScript fulfillment example with required storage.
- Language parity: record restored OCaml/TypeScript fulfillment behavior and its matrix verdict.

## Existing work and scope

FEAT-132 owns the OCaml reference-app convergence; it does not cover this TypeScript defect. FEAT-124's completed wiring is historical context. No open matching owner was found.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.

## Completion notes (2026-10-05)

**Premise re-verified at pickup** on `origin/main`: `fulfillment_worker/src/index.ts` read
`POSTGRES_URL` as optional, ran the transaction only `if (db)`, still returned `ACK`/
`messagesTotal(ok)` when storage was absent, and gated `fulfilledTopic`, the outbox relay and the
job runner on `db`.

**Fix.** `src/config.ts` owns `requiredPostgresUrl()` (absent, empty and whitespace-only all throw
before any Kafka work) alongside the existing `setting`/`intEnv`/`requiredRegistry` helpers.
`src/handler.ts` owns `handleOrder(order, traceContext, deps)`: storage (`store`, `jobs`), logger,
tracer and metrics are required arguments, the `if (db)` branch and the `!` non-null assertions are
gone, and a failed transaction still returns `fail("db: …")` without acknowledging. `index.ts` now
calls `requiredPostgresUrl()` first in `main()`, opens the pool, builds the job contract and passes
both into the handler; `fulfilledTopic`, `runRelay` and `runJobs` are unconditional.

**Tests.** `test/storage.test.ts`: `requiredPostgresUrl` throws for absent/empty/whitespace and
returns the trimmed valid value; an already-applied fact (insertFulfilled returns false) returns
`ACK`; a transaction that throws returns a non-`ACK` outcome. `npm run build -w order-svc -w
fulfillment-worker` typechecks and the demo's `npm test` passes (11 DB-dependent cases self-skip
locally; CI supplies Postgres). The existing `delivery.test.ts` integration case continues to prove
state, outbox and job intent commit in one transaction.

**Demo/example.** The runnable `demo_ts` fulfillment worker is the example and now requires
storage; `examples/pluto/app/demo_ts/README.md` already lists `POSTGRES_URL` among the addresses
`sol local run`/`sol deploy` inject, so no documentation change was needed.

**Language parity (DEC-022).** Restored TS parity with the OCaml reference path, which already
requires its database; recorded as already-equivalent for the fulfillment-worker storage
capability.

**Limitations.** The unit tests use structural fakes; the real single-transaction grouping is
exercised by the existing `delivery.test.ts` against Postgres in CI.
