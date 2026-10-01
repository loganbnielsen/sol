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
