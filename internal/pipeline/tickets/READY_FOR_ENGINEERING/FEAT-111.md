---
id: FEAT-111
type: feature
severity: high
title: Add a transactional outbox that preserves the domain's per-key order into Kafka
source: DEC-021 amendment (2026-09-29) — Kafka distributes facts; jobs perform retryable work
---

**Depends on:** None.

**Related:** `DEC-021` (the amendment this implements), `EXP-033` (the transaction-scope
spike that runs alongside this and does not gate it), `FEAT-112` (idempotent enqueue),
`FEAT-113` (removing Kafka message retry and application-level `Dead_letter`), `BUG-099`
(contract-driven partitioning and keying), `docs/reference/substrate.md`,
`framework/ocaml/sol-jobs/sol-jobs.md` (the sibling Postgres primitive whose claim/lease
posture this shares but whose ordering semantics it must not).

## What this is

A Postgres-backed transactional outbox: the application writes its domain state change and
the event describing it in **one transaction**, and a relay publishes those events to
Kafka. This is the producer-side half of the ordering model in `DEC-021`'s 2026-09-29
amendment:

```text
domain same-key serialization/version order
      → transactional outbox (atomic state + publication intent)
      → ordered per-key publication
      → Kafka partition order
```

The transactional system of record *records and preserves* the order the domain
establishes. It is not itself a domain-ordering API, and generic commit order is not the
contract.

No outbox exists today (`git grep -in outbox` finds nothing across `docs`, `framework`,
`cli` and the tickets), while the hazard is already documented: `sol-jobs.md` calls
transactional enqueue "the one thing Kafka structurally cannot give you". The outbox is
the same guarantee applied to events rather than work.

## Scope: one implementation, on Postgres

There is no `OUTBOX_BACKEND`, no `sol-outbox-postgres` / `sol-outbox-dynamodb` split, and
no pluggable storage interface. Postgres is Sol's opinionated storage layer, and a backend
enum gets designed the day a second implementation actually exists, not before (`DEC-021`,
on the worker backend; `docs/ROADMAP.md` Phase 4). A `sol-outbox` with a backend interface
and one backend is exactly the pluggability two decisions have already rejected.

The *pattern* is portable, and that belongs in the docs as an escape hatch for someone not
on Postgres — not in the package as an abstraction. If it is ever written down, record the
gap honestly: a DynamoDB `TransactWriteItems` outbox item is philosophically the same
thing, but DynamoDB Streams is not, because it emits storage changes rather than domain
events (the mapping becomes your architecture) and it retains records for 24 hours, so it
is not a durable queue you own.

## The contract, stated exactly

**Per-key order, with at-least-once publication:**

> For a given key, events are published in the order the domain established, and
> publication is at-least-once: a duplicate may be emitted, but never after a later event
> for that key, and never a gap.

Duplicates are possible; **gaps and inversions are not.** Consumers must be idempotent
(version-aware) and must not need to reorder.

**Atomicity is at the transaction, not at Kafka:**

```text
state transaction commits  ⇔  its outbox record commits
committed unpublished outbox record  →  eventually published
```

"An event exists iff the state change committed" holds of the **outbox record — the
publication intent** — never of the Kafka record, because publication is asynchronous.
That distinction is the whole reason the outbox exists.

**The relay protocol that produces the contract.** For the oldest unpublished event of a
key:

```text
produce → await the broker receipt
    ├── failure → leave unpublished, do not advance the key
    └── acknowledged → mark published → next event for that key
```

Two things it makes load-bearing:

- **"Published" means the broker acknowledged**, not "handed to the producer". In
  `kafka-eio`, `Kafka.Producer.produce_await` returns `(unit, Kafka_error.t) result
  Eio.Promise.t` (`kafka_producer.mli:95`), so the relay must `Eio.Promise.await` the
  promise before marking. Marking on the promise itself reproduces the silent-loss bug
  class already recorded against `publish_raw`
  (`internal/pipeline/audits/2026-06-08_audit.md`: `ignore (produce_await …)` then `ack()`
  unconditionally, so a failed publish was acked and lost).
- **The invariant is "never advance past an unpublished row", and its price is duplicates
  rather than loss.** A relay that marks *before* publishing, to stop a second relay
  double-publishing, loses the event permanently if it dies in between. That is the wrong
  trade, and it is why the protocol is publish-then-mark-on-receipt.

**A key's ordering token comes from the domain, not from the table.** Define how a key's
ordering token is assigned *while that key is serialized* — a per-key version, or a value
the domain assigns under the same lock or compare-and-set that makes the mutation serial.
A global monotonic column is a legitimate *implementation* of that token, but it is not
the semantic fallback: "order by the global sequence" must not be able to smuggle generic
database commit order back in as domain order. The relay obeys the per-key token; a global
column serves scanning, cleanup and tie-breaking.

## Relay: v1 is one logical owner, and scaling is a trigger, not a design

- **v1 runs a single logical relay owner per database.** One producer can push a great deal
  of data into Kafka. Designing distributed ownership before measuring that it is needed is
  the speculative distributed-systems work this repo avoids.
- **The relay has an explicit Sol-managed lifecycle** — a defined process/deployment with a
  named owner, not a polling fiber that every service replica happens to run. Silent N-way
  relay contention is the failure that avoids.
- **Overlapping relay ownership is a correctness problem, not a performance one.** Two
  owners publishing a key can invert it, and ordinary leases alone do not prevent it: a
  relay whose lease expired but which is still alive can publish after the new owner, and a
  plain Kafka producer carries no fencing token to stop it. This is recorded as a known
  hazard, not as a design.
- **Scaling trigger:** when measured relay throughput is inadequate for a deployment, that
  is when an ownership/fencing design is spiked and chosen. Kafka transactional-producer
  fencing (a stable `transactional.id`, so the broker's producer epoch rejects a stale
  owner — `Kafka.Producer.with_transaction` already exists in the client) is one candidate
  to evaluate then, alongside others. This ticket deliberately chooses no mechanism in
  advance.

## Design requirements

- **Transaction-scoped publication.** `Outbox.publish` participates in the caller's
  transaction and never opens its own. `EXP-033` decides whether transaction scope is
  represented in the type system — so that `Outbox.publish pool event` is a type error —
  or stays a documented convention with the atomicity test below as the guard.
- **Per-key ordered publication.** The outbox row carries the aggregate key and the
  ordering token defined above. The relay publishes with the aggregate key as the Kafka
  key, so downstream per-partition order is the published order.
- **An order-preserving relay, with the mechanism left to the implementation.** The
  invariant is what matters. The naive approach is anti-order — `sol-jobs`' `FOR UPDATE
  SKIP LOCKED` per-row claiming lets two claimers publish a key's second event before its
  first — so the relay must exclude that. The implementation chooses and *justifies* the
  simplest workable scheme; this ticket fixes the invariant and the test, not the
  mechanism.
- **Stable event identity and dedup.** Every event carries a stable id generated at write
  time; it need not be derivable from the domain shape (a ULID is fine). State the
  consumer-side dedup story. Suppressing *duplicate logical commands* is an idempotency-key
  concern at the API boundary, not part of event identity.
- **Failure visibility, not a silent gap.** A publish that cannot succeed blocks *later
  events for that key* — which is correct — and must be a per-key publication-lag metric
  and an alert, not a silent gap.
- **Retention, index and cleanup.** Published rows are short-lived: Kafka is the durable
  replay log, and Postgres must not become a second one. Design the scan (a partial index
  on unpublished rows), prefer delete over update to avoid bloat, and support time-partition
  drop for bulk cleanup. State whether rows are retained at all after publication, and why.
- **Latency.** A polling relay adds publication latency. State the default and the knob.
  Do not silently depend on `LISTEN`/`NOTIFY` (`sol-jobs`' non-goal); if the latency is
  unacceptable, revisit that explicitly for the outbox.
- **Composition with `sol-jobs`.** An application that enqueues a job and publishes an
  event in one transaction must not need two mechanisms; state how the outbox and
  `sol-jobs` enqueue compose, with a test.

## Non-goals

- Not a general event log and not a Kafka replacement. Kafka remains the distribution and
  replay layer, and consumers never poll the outbox.
- Not a CDC/Debezium integration. An application-managed outbox is explicit and needs no
  connector; WAL capture would be its own decision.
- Not a scheduler or a job queue. That is `sol-jobs`.
- No per-key ordering guarantee in `sol-jobs`; that stays an explicit non-goal.
- Not a pluggable storage backend, and not a distributed relay.

## Acceptance criteria

- A state change and its outbox row commit or roll back together: a test returns an error
  from inside the transaction and asserts that neither the domain row nor the outbox row
  exists and that nothing was published.
- Per-key publication order is preserved under a concurrent relay: a mutation-tested test
  fails if a key's events are published out of order.
- A relay killed after `produce` but before the receipt resolves republishes the same
  event first on recovery and does not advance the key — a duplicate prefix, not an
  inversion and not a gap.
- The relay marks a row published only after the delivery receipt resolves.
- The relay publishes the aggregate key as the Kafka key, and a multi-partition test shows
  per-key order preserved downstream.
- A blocked publish is visible as a per-key lag metric and an alert, and blocks only that
  key.
- Retention, index and cleanup behavior are documented and exercised, and duplicate
  delivery is shown not to break a consumer.
- The outbox composes with `sol-jobs` transactional enqueue in one transaction, with a
  test.
- The contract's limits are documented where an application author reads them: duplicates
  possible, consumer idempotency required, per-key order is the domain's order.

**Demo/example coverage:** `examples/pluto` must gain a path that writes state and event in
one transaction, deploy it, and show the event arriving in order; the tutorial must show the
same.

**TypeScript parity:** required or explicitly deferred with a trigger — a TS application
needs the same transactional publication path, and today there is no TS `sol-jobs`
equivalent either (DEC-022). Silence is not a verdict.
