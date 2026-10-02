---
id: FEAT-123
type: feature
severity: low
title: "TypeScript parity: the worker consumer must absorb duplicate fact delivery"
source: "BUG-112 (the OCaml consumer's domain insert duplicated a redelivered fact)"
---

TypeScript parity: the worker consumer must absorb duplicate fact delivery

**Depends on:** None.

## Problem

`BUG-112` fixed the OCaml consumer in `examples/pluto`: a redelivered `Charged` fact duplicated
the `pluto_notifications` row until the insert gained a unique key and `ON CONFLICT DO NOTHING`.
The outbox contract is at-least-once and a duplicate is a legal outcome in both languages
(DEC-022), so the TypeScript consumer owes the same property.

`examples/pluto/app/demo_ts/fulfillment_worker` consumes its event through `@sol-fab/kafka` and
writes its own row; whether a redelivered fact duplicates it is neither stated nor tested.

## Remediation

State and demonstrate the TypeScript consumer's duplicate-delivery story — an idempotent write
keyed by the fact's stable identity, matching the OCaml consumer — in the TS golden path, and
record the verdict in the capability matrix.

## Acceptance criteria

- Delivering the same fact twice leaves one row and one independent effect in the TypeScript pair.
- The TypeScript golden path shows the guard.
- The capability matrix records the consumer-idempotency verdict for both languages.

## Premise check (2026-10-02)

Partly stale. `examples/pluto/app/demo_ts/fulfillment_worker/src/db.ts` already
declares `order_id TEXT PRIMARY KEY` and inserts with
`ON CONFLICT (order_id) DO NOTHING`, so a redelivered fact cannot duplicate the
row — the guard exists. What is missing is the *statement* in the golden path and
a *test*; the demo has no test harness, so demonstrating the property needs
either a Postgres-backed test or a documented manual check. Re-scope this ticket
to that before implementing, or close it as covered by the existing guard.

## Unblocked (2026-10-02)

FEAT-126 resolved the "independent effect" half: `fulfillment_worker` now
enqueues a `send_confirmation` job in the same transaction as its row, keyed by
the order id, so a redelivered fact leaves one row **and** one job. Both halves
of the property are therefore implemented; what remains is the statement in the
golden path, a Postgres-backed test for it, and the capability-matrix verdict.

The demo can now carry a test: CI gives the TypeScript job a Postgres service in
the pattern `sol-typescript`'s `@sol-fab/jobs` suite already uses, and cases
self-skip without `POSTGRES_URL`.


