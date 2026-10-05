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
