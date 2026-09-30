---
id: FEAT-111
type: feature
severity: high
title: Add a transactional outbox that preserves the domain's per-key order into Kafka
source: DEC-021 amendment (2026-09-29) — Kafka distributes facts; jobs perform retryable work
---

**Depends on:** None.

**Related:** `DEC-021` (the amendment this implements), `FEAT-112` (the
consumer→jobs half of the same boundary), `FEAT-113` (removing Kafka message retry
and application-level `Dead_letter`), `BUG-099` (contract-driven partitioning and
keying), `DEC-021`'s DLQ amendment (group-scoped DLQ naming),
`docs/reference/substrate.md`, `framework/ocaml/sol-jobs/sol-jobs.md` (the sibling
Postgres primitive whose claim/lease posture this shares but whose ordering
semantics it must not).

## What this is

A Postgres-backed transactional outbox: the application writes its domain state
change and the event describing it in **one transaction**, and a relay publishes
those events to Kafka. This is the producer-side half of the ordering model in
`DEC-021`'s 2026-09-29 amendment:

```text
domain same-key serialization/version order
      → transactional outbox (atomic state + publication intent)
      → ordered per-key publication
      → Kafka partition order
```

The transactional system of record *records and preserves* the order the domain
establishes. It is not itself a domain-ordering API, and generic commit order is not
the contract.

No outbox exists today (`git grep -in outbox` finds nothing across `docs`,
`framework`, `cli` and the tickets), while the hazard is already documented:
`sol-jobs.md` calls transactional enqueue "the one thing Kafka structurally cannot
give you". The outbox is the same guarantee applied to events rather than work.

## The guarantee, stated exactly

- **Atomicity is at the transaction, not at Kafka.** The precise invariant is
  two-sided:

  ```text
  state transaction commits  ⇔  its outbox record commits
  committed unpublished outbox record  →  eventually published at least once
  ```

  So "an event exists iff the state change committed" holds of the **outbox record —
  the publication intent** — and never of the Kafka record: publication is
  asynchronous and can be delayed or failing while the intent is already durable. That
  distinction is the whole reason the outbox exists, and the documentation must not
  collapse it.
- **Order is the domain's order, preserved.** The domain establishes same-key
  serialization or version order; the outbox records publication intent in the same
  transaction and preserves that order into ordered per-key publication. If two
  concurrent transactions touch the same key and the domain does not serialize them,
  the outbox publishes the race faithfully. It does not manufacture causality, and the
  documentation must not claim it does — commit order is the mechanism that records
  publication intent, not the ordering contract.

## Design requirements

- **Per-key ordered publication.** The outbox row carries the aggregate key and the
  order the domain established for that key — a per-key version where the domain has
  one, or a sequence assigned while the key is serialized. The relay publishes with
  the aggregate key as the Kafka key, so downstream per-partition order is the
  published order.
- **An order-preserving relay, with the mechanism left to the implementation.** The
  invariant is what matters: under concurrency, a key's events are published in order.
  The naive approach is anti-order — `sol-jobs`' `FOR UPDATE SKIP LOCKED` per-row
  claiming lets two relay instances publish key A's second event before its first — so
  the relay must exclude that. The implementation ticket chooses and *justifies* the
  simplest workable scheme (per-key claiming, partitioned relay ownership by key, or a
  single ordered relay at the scale v1 supports); this ticket fixes the invariant and
  the test, not the mechanism. A mutation-tested test must fail if a key's events are
  published out of order under a concurrent relay.
- **Recording order is not the ordering contract.** Document how the row's stored
  order preserves the domain's per-key order, and what an application must do to
  establish that order — serialize the key, or carry a version. Generic global commit
  order is out of scope; Kafka is per-partition anyway.
- **Stable event identity and dedup.** At-least-once relay means duplicate publishes
  are possible. Every event carries a stable id (stable across retries, never
  reused), and the consumer-side dedup story is stated.
- **Failure visibility, not a silent gap.** A publish that cannot succeed retries;
  because order matters it blocks *later events for that key* — which is correct —
  and that must be a metric and an alert, not a silent gap.
- **Retention.** Decide whether published rows are deleted (cleanup, like
  `sol-jobs`) or retained for replay or audit. If retained, say what the retention is
  for; do not rebuild Kafka's log in Postgres.
- **Latency.** A polling relay adds publication latency. State the default and the
  knob. Do not silently depend on `LISTEN`/`NOTIFY` (`sol-jobs`' non-goal); if the
  latency is unacceptable, revisit that explicitly for the outbox.
- **Composition with `sol-jobs`.** An application that enqueues a job and publishes
  an event in one transaction must not need two mechanisms; state how the outbox and
  `sol-jobs` enqueue compose, with a test.

## Non-goals

- Not a general event log and not a Kafka replacement. Kafka remains the
  distribution and replay layer.
- Not a CDC/Debezium integration. An application-managed outbox is explicit and
  needs no connector; WAL capture would be its own decision.
- Not a scheduler or a job queue. That is `sol-jobs`.
- No per-key ordering guarantee in `sol-jobs`; that stays an explicit non-goal.

## Acceptance criteria

- A state change and its outbox row commit or roll back together; a test fails if an
  event is published for a rolled-back transaction, or lost after a commit.
- Published order equals the domain-established per-key order: a concurrent-relay test
  fails if a key's events are published out of order.
- The relay publishes the aggregate key as the Kafka key, and a multi-partition test
  shows per-key order preserved downstream.
- A blocked publish is visible as a metric and an alert and blocks only that key.
- Retention and dedup semantics are documented, and duplicate delivery is shown not
  to break a consumer.
- The outbox composes with `sol-jobs` transactional enqueue in one transaction, with
  a test.
- The guarantee's limit (same-key writes must establish their own order) is documented
  where an application author reads it.

**Demo/example coverage:** `examples/pluto` must gain a path that writes state and
event in one transaction, deploy it, and show the event arriving in order; the
tutorial must show the same.

**TypeScript parity:** required or explicitly deferred with a trigger — a TS
application needs the same transactional publication path, and today there is no TS
`sol-jobs` equivalent either (DEC-022). Silence is not a verdict.
