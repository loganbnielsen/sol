---
id: FEAT-124
type: feature
severity: medium
title: "TypeScript parity: a transactional outbox that publishes ordered facts with the domain write"
source: "VERIF-001 (the outbox flow is proven on the OCaml side; DEC-022 records no TypeScript counterpart)"
---

TypeScript parity: a transactional outbox that publishes ordered facts with the domain write

**Depends on:** None.

**Related:** FEAT-111 (the OCaml outbox this mirrors), FEAT-121 (the pluto wiring),
FEAT-123 (the TypeScript consumer's duplicate-delivery half), FEAT-119 (event-contract
projection), FEAT-118 (the `Ack | Fail` worker contract), FEAT-080 (the capability matrix),
DEC-022, DEC-021's 2026-09-29 amendment.

## Problem

The OCaml framework has a Postgres transactional outbox (FEAT-111): a domain change and the
event describing it commit in one transaction, and a relay publishes those events per key in
order. `VERIF-001` now proves that composition end to end, with its failure boundaries
(rollback, broker outage, duplicate delivery, `Fail`, transient job retry, same-key ordering,
the publish/mark crash boundary).

The TypeScript side has no counterpart. `@sol-fab/kafka` publishes records, but there is no
TypeScript outbox that commits publication intent with the domain write, and no relay host.
A TypeScript service therefore cannot offer the same atomicity and per-key ordering guarantee
an OCaml `sol-svc` does, and the capability matrix (FEAT-080) records no verdict for this
capability at all — silence, which is the failure DEC-022 exists to prevent.

## Remediation

Give TypeScript the same contract, not the same implementation: a `@sol-fab/outbox` (or an
extension of an existing package) that writes the outbox row in the caller's Postgres
transaction, and a relay that publishes pending rows per key in order, only marking a row
published after the broker acknowledges it. It must uphold the semantics VERIF-001 exercises
against the OCaml implementation: at-least-once publication, duplicates rather than gaps or
inversions, a blocked earlier event holding later events for the same key, and
`sol_outbox_pending` / `sol_outbox_oldest_pending_seconds` telemetry.

The outbox's sibling `sol-jobs` is already recorded as **intentionally deferred**, sequenced
after FEAT-082; this ticket is separable from it and its trigger is the same kind of demand:
a real TypeScript application that needs the facts-to-jobs composition.

## Acceptance criteria

- A TypeScript service can commit a domain change and an outbox intent in one transaction and
  have the relay publish it as an ordered, keyed Kafka fact.
- The relay marks a row published only after the broker acknowledges it, and a crash between
  the ack and the mark produces a duplicate, never a gap or an inversion.
- A blocked earlier event for one key does not let a later event for that key publish first.
- `@sol-fab/kafka`'s (or the new package's) tests cover the boundaries VERIF-001 exercises on
  the OCaml side, and the TypeScript golden path (`examples/pluto/app/demo_ts/`) demonstrates
  the split.
- The capability matrix records the outbox verdict for both languages.

**Demo/example coverage:** the TypeScript golden path must show the composition, as
`examples/pluto/app/comms/notify_worker` does for OCaml.

**TypeScript parity:** this ticket *is* the TypeScript side of the capability VERIF-001 proves
for OCaml.
