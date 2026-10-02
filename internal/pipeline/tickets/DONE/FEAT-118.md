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

## Done (2026-10-02)

**Premise checked.** Confirmed at `sol-kafka@17b4356`: `outcome.ts` still declared
`Ack | Retry | Dead_letter` with `RetryStrategy`, and the demo worker imported
`kafkaRetryRelay`/`runRetryRelayConsumer`/`wrapEachRetryableMessage`. Premise held.

**What landed.**

- `loganbnielsen/sol-kafka#6` (merged `8fd2b1c`) replaces the retry-topic relay with
  the `Ack | Fail` contract: `ACK` commits; `fail(reason)` throws
  `MessageFailError`, and `wireCrashListener` stops the consumer and exits 0
  (mirroring `worker.ml`'s `| Fail -> ... Consumer.Stop`). Retries, the retry
  topic, `RetryStrategy`, the backoff policy and `routing.ts` are gone. Released
  as `@sol-fab/kafka@0.4.0` (tag `v0.4.0`).
- The group-scoped decode DLQ is kept, in `dlq.ts`: `dlqTopicName` / the
  always-12-hex `canonicalGroupSegment` (BUG-117), `decodeFailureHeaders`
  (`X-Sol-Decode-Error` / `X-Sol-Origin-Group`), and `provisionDlqTopic`, which
  creates the DLQ at the source's live-or-declared partition count — mirroring
  `Kafka_service.consume`'s `ensure_topic` under `Route_to_dlq`. A `route-to-dlq`
  offset commits only once the publish lands; a failed publish throws.
- `loganbnielsen/sol-obs#7` (merged `d0b8aac`) narrows `WorkerMessageStatus` to
  `ok | fail | ack_failed`, matching `worker.ml`; released as
  `@sol-fab/obs@0.3.0` (tag `v0.3.0`).
- `examples/pluto/app/demo_ts/fulfillment_worker` consumes both: `provisionDlqTopic`,
  `wrapEachMessage` with a `dlq` publisher, an `ACK`/`fail("db: …")` handler, and
  `wireCrashListener`'s `onFailStop` wired to `runWorker`'s `lifecycle.shutdown()`
  so a `Fail` drains and flushes before exiting.

**Checks run.** `sol-kafka`: `tsc` clean; 48 tests, 47 pass + 1 broker-gated skip
(new `consume.test.ts` and `dlq.test.ts` cover the DLQ route, the failed-publish
throw, `ack-and-drop`, the `Ack`/`Fail` outcomes, the fail-stop, and the DLQ
naming/headers against the OCaml fixtures). `sol-obs`: `tsc` clean, 16 tests pass.
Demo: `npm run build -w order-svc -w fulfillment-worker` clean against
`kafka@0.4.0` / `obs@0.3.0`.

**Demo/example coverage.** This ticket *is* the TypeScript example update.

**Language parity.** Closes the outcome, DLQ-routing and worker-metric rows of the
capability matrix; the matrix (`2026-10-02_cross_language_contract_audit.md`) now
records those verdicts as implemented. The independent-retryable-work half is
FEAT-126, so the `sol-jobs` row stays deferred and is not claimed here.

