---
id: FEAT-113
type: refactor
severity: high
title: Remove Kafka message-level retry and application-level Dead_letter
source: DEC-021 amendment (2026-09-29) — Kafka distributes facts; jobs perform retryable work
premise: "! rg -q 'Make_with_retry' framework/ocaml/sol-worker/lib/worker.mli"
---

**Depends on:** BUG-099, FEAT-112.

`FEAT-112` is a dependency, not merely related work. Removing message-level retry
makes Kafka → `sol-jobs` the endorsed composition for independently retryable work,
and that composition is not safe until `enqueue` deduplicates. Landing the deletion
first would replace a working mechanism with a recommended one that still carries the
Kafka↔Postgres at-least-once hole.

**Related:** `DEC-021` (the amendment this implements), `FEAT-111` (the outbox),
`FEAT-114` (the operation-retry helper), `FEAT-078` (the two-tier split this
collapses), `BUG-104` and `BUG-097` (retry-path units this makes moot), `DOCS-015`.

## Decision

Settled by the operator on 2026-09-29 and recorded in `DEC-021`'s amendment:

- **Application-level `Dead_letter` is removed.** Once a valid decoded fact reaches
  the handler, the outcome is exactly `Ack | Fail`. A handler that declines to apply a
  fact fails, and the offset does not advance. It does not get to declare a fact
  permanently unprocessable and advance past it — that would violate the amendment's
  invariant that Sol must not advance past a fact it did not successfully consume —
  and it spares application code having to make a reliable "this can never succeed"
  judgment at runtime.
- **Framework decode and schema failures keep their DLQ.** The handler never received
  a domain fact there, so parking the record is transport/schema failure handling, not
  a skipped fact.
- A permanent semantic mismatch, an unsupported domain version, or an invariant
  violation is evidence that the consumer, the deployment, or the contract is wrong.
  It surfaces as a stopped consumer and an operator-visible contract failure.
- If a concrete workload ever shows that a decoded fact should legitimately not block
  its consumer, the answer is an explicitly named semantic primitive designed against
  that workload — not a generic escape hatch preserved in advance.

## Premise

Checked 2026-09-29 at `origin/main` `d27f8710`: `Make_with_retry` exists in the
public worker interface, `Worker.Retry`/`Worker.Dead_letter` and `retry_policy` are
public, and `Kafka_service.Retry_topics` plus the retry relay exist in
`kafka-eio-service`. The probe is stale exactly when the retry surface is gone.

## Why the prerequisite

BUG-099 must land first. `kafka_service_config.ml` fixes `partitions = 1`, so `Fail`
would stop *all* processing for the worker — not just the affected key — and a live,
heartbeating consumer never hands the only partition to a standby. Removing retry
before contract-driven partitioning exists converts a rare poison record into a
whole-worker outage. This deletion is what turns BUG-099 from a bug fix into a
load-bearing contract.

## What this removes

`Make_with_retry`, `RETRYABLE_WORKER`, `~retry_policy`, `retry_strategy`,
`retry_policy`/`default_retry_policy`, `Worker.Retry`, `Worker.Dead_letter`, the
retry-topic relay and its consumer, `X-Sol-Retry-Attempt` and `X-Sol-Retry-At`,
group-scoped retry topics, and the retry-partition head-of-line limitation. `Make`
becomes the single tier, and its `handle` returns the two-case `Ack | Fail` outcome.

## What stays

- DLQ publication for decode and schema failures. The per-group DLQ naming and
  provenance rules from `DEC-021`'s DLQ amendment are unchanged.
- The acknowledgement-ownership invariant: the framework commits the offset, never
  the handler.

## Mooted units

`BUG-104` (release retry-topic records by due time) and `BUG-097` (honour shutdown in
Retry_topics workers) describe the machinery this removes. When this lands, reconcile
them explicitly — point each at the removal rather than silently closing it.

## Acceptance criteria

- No retry mechanism, and no application-level `Dead_letter`, remains in the
  `sol-worker` or `kafka-eio-service` public API, or in the generated scaffold.
- The worker outcome vocabulary is exactly `Ack | Fail`, and the ack-ownership
  invariant is preserved.
- A `Fail` does not advance the offset, surfaces a metric and an alert, and is tested
  against a real broker.
- DLQ delivery for a decode or schema failure still works and is tested.
- `sol-worker.md`, `kafka-eio-service.md`, the tutorial, the alert runbooks, and
  `examples/pluto`/venus describe one mechanism.
- `BUG-104` and `BUG-097` are reconciled in the completion notes.
- TypeScript parity: `@sol-fab/worker`'s retry and `dead_letter` semantics are aligned,
  or the delta is recorded with a trigger (DEC-022).

**Demo/example coverage:** pluto/venus and the tutorial must show the new contract — a
fact consumed, and an independent effect handed to `sol-jobs` rather than retried on
the stream.
