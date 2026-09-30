---
id: FEAT-118
type: feature
severity: medium
title: Align @sol-fab/kafka and @sol-fab/worker with Sol's Ack | Fail worker contract
source: "FEAT-113 (DEC-021 amendment 2026-09-29); DEC-022 TypeScript-parity tracking"
---

**Depends on:** None.

**Related:** FEAT-113 (the OCaml removal this mirrors), FEAT-080 (the capability matrix), DEC-022, DEC-021's 2026-09-29 amendment.

## Problem

FEAT-113 removed Kafka message-level retry and application-level `Dead_letter` from the OCaml framework. The worker outcome vocabulary is exactly `Ack | Fail`; a `Fail` leaves the offset uncommitted and stops the consumer; only framework decode/schema failures are dead-lettered (to the group-scoped DLQ); and independently retryable work goes to `sol-jobs`, enqueued in the transaction that caused it.

The published TypeScript packages still carry the old mechanism. `examples/pluto/app/demo_ts/fulfillment_worker/src/index.ts` imports `kafkaRetryRelay`, `provisionRelayTopics`, `retry`, `runRetryRelayConsumer`, `wrapEachRetryableMessage`, and `RetryStrategy` from `@sol-fab/kafka`, and returns `retry(...)` on a DB failure — the retry-topic relay and `Ack | Retry | Dead_letter` vocabulary FEAT-113 deleted in OCaml.

Per DEC-022, parity is capability and behavioural, not implementation: the TypeScript worker must express the same contract — outcome `Ack | Fail`, fail-stop with the offset uncommitted, DLQ only for decode/schema failures, and a transactional `sol-jobs` handoff for independent retryable work — while keeping the Node ecosystem underneath.

## Remediation

The `@sol-fab` packages live in their own repositories, outside this one. Align them with the FEAT-113 contract:

- Reconcile `@sol-fab/kafka` and `@sol-fab/worker`: drop the retry-topic relay, `RetryStrategy`, and the `Ack | Retry | Dead_letter` outcome; expose `Ack | Fail`.
- Keep framework decode/schema DLQ publication with the same group-scoped naming (`<source>.<canonical-group>.dlq`) and provenance headers (`X-Sol-Decode-Error`, `X-Sol-Origin-Group`).
- Provide a durable job queue (or an equivalent transactional, dedupe-keyed enqueue) so the Kafka → job handoff is idempotent, matching `sol-jobs`.
- Update `examples/pluto/app/demo_ts/fulfillment_worker` to the new contract, and refresh the per-capability verdicts in `internal/pipeline/dogfood/2026-09-07_typescript_demo_spike.md` (FEAT-080).

## Acceptance criteria

- `@sol-fab/worker`'s outcome vocabulary is `Ack | Fail`, with no retry policy, relay, or application-level dead-letter outcome.
- A decode/schema failure is parked on the group DLQ with the same naming and headers as the OCaml side; a handler `Fail` leaves the offset uncommitted.
- Independent retryable work is handed to a durable job queue with an idempotent (dedupe-keyed) enqueue.
- `examples/pluto/app/demo_ts` builds and demonstrates the same fact-consumed → job-enqueued composition as the OCaml `notify_worker`.
- FEAT-080's capability matrix records the aligned verdict.

**Demo/example coverage:** this ticket *is* the TypeScript example update.

## Blocked On

The next `@sol-fab/*` release after FEAT-113 lands. Until then Sol's own OCaml framework is the single implementation of the contract, and the TypeScript demo reflects the pre-FEAT-113 packages it pins (`@sol-fab/kafka@^0.2.0`, `@sol-fab/worker@^0.1.0`); the capability matrix records the delta with this ticket as its trigger.
