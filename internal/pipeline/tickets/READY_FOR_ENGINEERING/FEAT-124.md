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

## Design (2026-10-02): a new package, not an extension

**A new `@sol-fab/outbox` in `loganbnielsen/sol-typescript`** (alongside `svc`/`worker`/`jobs`,
the same repository FEAT-126 established for a new Postgres-backed contract). Extending an
existing package was rejected on substance, not taste: `@sol-fab/kafka` deliberately has no
Postgres dependency — it is the Kafka policy layer, and the outbox is a storage-side
primitive that injects its publish callback so it needs no Kafka dependency either; folding
it into `@sol-fab/jobs` would put two different contracts (events vs. jobs, per-key order vs.
claim-once) under one name.

The API mirrors `framework/ocaml/sol-outbox`'s observable contract (DEC-022):

- `publish(client, contract, event, { key, ord })` is a plain `INSERT`. Taking a `PoolClient`
  is what makes it join the caller's transaction — the same shape `@sol-fab/jobs.enqueue` uses,
  and `ord` is the caller's per-key ordering token, never a generated sequence.
- `runRelay({ pool, publish, signal, ... })` scans the oldest unpublished row of each key
  (`ord = min(ord)` per key, ordered by `id`), calls the injected `publish`, and `DELETE`s the
  row only after it resolves; a publish failure leaves the row and does not advance the key.
  One relay owner in v1, exactly as the OCaml spec records.
- It exports the `sol_outbox_published_total` / `sol_outbox_pending` /
  `sol_outbox_oldest_pending_seconds` names and an `onMetrics` snapshot, so the app wires the
  same Grafana panels an OCaml service feeds.

`examples/pluto/app/demo_ts/fulfillment_worker` composes the split the way the OCaml
`notify_worker` does: the fulfilled-order row, the confirmation job and the outbox intent
commit in one transaction, and the worker hosts the relay, publishing through
`@sol-fab/kafka` with the event key so partition order is the published order.

**Publishing.** npm rejects `npm trust` for a package that does not exist yet, so `0.1.0` is
bootstrapped with one authenticated publish (no provenance) and its trusted publisher is
configured immediately afterwards; every release from `0.1.1` goes through the tag-triggered
OIDC workflow with provenance, like `svc`/`worker`/`jobs`.

## Progress (2026-10-02)

The package is implemented, tested and merged: `loganbnielsen/sol-typescript#8` (merged
`c1ea404`) adds `@sol-fab/outbox@0.1.0` with `publish`/`runRelay`/`pending`/`pendingCount`, the
`sol_outbox_*` metric names, and 11 tests against a real Postgres covering rollback, the
`(key, ord)` unique index, per-key ordering, a blocked key holding later events, and the
ack/mark crash boundary. `release.yml` gained the `outbox-v*` tag.

## Blocked On

The bootstrap publish of `@sol-fab/outbox@0.1.0`. npm refuses `npm trust` for a package that
does not exist yet (`404 Package not found`), so `0.1.0` needs one interactive,
2FA-authenticated publish before its OIDC trusted publisher can be configured. Attempted from
this environment and stopped at the credential boundary:

```text
$ npm publish --access public --workspace=packages/outbox
npm error code EOTP
npm error This operation requires a one-time password.
npm error   https://www.npmjs.com/auth/cli/***
```

**Operator action:** run
`npm publish --access public --workspace=packages/outbox` in `~/Code/sol-typescript` at
`origin/main` and complete the browser 2FA, then
`npm trust github @sol-fab/outbox --file release.yml --allow-publish`. From `0.1.1` on the
tag-triggered OIDC workflow publishes with provenance.

Blocked on that: the remaining Sol-side work — `examples/pluto/app/demo_ts` composing the
domain write, the job and the outbox intent in one transaction and hosting the relay, plus the
capability-matrix verdict — needs `@sol-fab/outbox` resolvable from npm.
