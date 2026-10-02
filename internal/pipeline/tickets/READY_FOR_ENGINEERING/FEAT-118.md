---
id: FEAT-118
type: feature
severity: medium
title: Align @sol-fab/kafka with Sol's Ack | Fail worker contract (outcome, fail-stop and decode DLQ)
source: "FEAT-113 (DEC-021 amendment 2026-09-29); DEC-022 TypeScript-parity tracking"
---

**Depends on:** None.

**Related:** FEAT-113 (the OCaml removal this mirrors), FEAT-126 (the transactional sol-jobs handoff, split out), FEAT-080 (the capability matrix), DEC-022, DEC-021's 2026-09-29 amendment.

## Problem

FEAT-113 removed Kafka message-level retry and application-level `Dead_letter` from the OCaml framework. The worker outcome vocabulary is exactly `Ack | Fail`; a `Fail` leaves the offset uncommitted and stops the consumer; and only framework decode/schema failures are dead-lettered, to the group-scoped DLQ.

The published TypeScript packages still carry the old mechanism. `examples/pluto/app/demo_ts/fulfillment_worker/src/index.ts` imports `kafkaRetryRelay`, `provisionRelayTopics`, `retry`, `runRetryRelayConsumer`, `wrapEachRetryableMessage`, and `RetryStrategy` from `@sol-fab/kafka`, and returns `retry(...)` on a DB failure — the retry-topic relay and `Ack | Retry | Dead_letter` vocabulary FEAT-113 deleted in OCaml.

Per DEC-022, parity is capability and behavioural, not implementation: the TypeScript worker must express the same contract — outcome `Ack | Fail`, fail-stop with the offset uncommitted, DLQ only for decode/schema failures — while keeping the Node ecosystem underneath.

The vocabulary lives in `@sol-fab/kafka` (`outcome.ts`); `@sol-fab/worker` owns only the process lifecycle and is unchanged by this ticket.

## Remediation

The `@sol-fab` packages live in their own repositories, outside this one. Align them with the FEAT-113 contract:

- Drop the retry-topic relay, `RetryStrategy`, backoff policy and the `Ack | Retry | Dead_letter` outcome from `@sol-fab/kafka`; expose `Ack | Fail`.
- `Fail` is fail-stop: the offset stays uncommitted and the consumer stops, mirroring `worker.ml`'s `| Fail -> ... Kafka.Consumer.Stop`.
- Keep framework decode/schema DLQ publication with the same group-scoped naming (`<source>.<canonical-group>.dlq`) and provenance headers (`X-Sol-Decode-Error`, `X-Sol-Origin-Group`) as `kafka_service_dlq.ml`.
- Update `examples/pluto/app/demo_ts/fulfillment_worker` to the new contract, and refresh the per-capability verdicts in `internal/pipeline/dogfood/2026-09-07_typescript_demo_spike.md` (FEAT-080).

## Acceptance criteria

- `@sol-fab/kafka`'s outcome vocabulary is `Ack | Fail`, with no retry policy, relay, or application-level dead-letter outcome.
- A decode/schema failure is parked on the group DLQ with the same naming and headers as the OCaml side; a handler `Fail` leaves the offset uncommitted and stops the consumer.
- `examples/pluto/app/demo_ts` builds and demonstrates the new contract.
- FEAT-080's capability matrix records the aligned verdict for the outcome/DLQ rows.

**Demo/example coverage:** this ticket *is* the TypeScript example update.

## Scope note

The transactional `sol-jobs` handoff that this ticket originally bundled is **FEAT-126**: it needs a new published `@sol-fab/*` package, which is operator-gated on repository and trusted-publishing setup. Splitting it keeps this ticket's outcome/DLQ half closeable now; FEAT-080's `sol-jobs` obligation is carried by FEAT-126.
