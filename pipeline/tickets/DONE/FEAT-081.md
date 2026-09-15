---
id: FEAT-081
type: feature
severity: medium
source: FEAT-080 reconciliation 2026-09-15 — the capability table's one
  confirmed gap
---

**Depends on:** None.

**Related:** FEAT-034, FEAT-035, FEAT-076, FEAT-078, DEC-021, FEAT-080.

Give `@sol/kafka` the retry/DLQ contract `sol-worker` already has, so a
TypeScript worker can participate in Sol's retry/DLQ machinery exactly as an
OCaml `sol-worker` does.

## Problem

FEAT-080's reconciliation confirmed this as the only place the TS side is
missing a Sol *convention* rather than using an ecosystem library:

- `@sol/kafka`'s `wrapEachMessage`
  (`packages/sol-kafka/src/consume.ts`) predates FEAT-076/078. It exposes a
  two-way split only — decode failure = reject, handler failure = let
  `kafkajs` retry — with no way for a handler to return `Retry reason` /
  `Dead_letter reason`, and no `retry_strategy` to select.
- It therefore inherits `kafkajs`'s implicit retry as the fallback, exactly
  the "implicit default substrate behavior standing in for an explicit Sol
  decision" FEAT-078 removed on the OCaml side. The tiers don't line up:
  OCaml has Ack-only and retry-capable-is-declared; TS has one
  always-retrying wrapper.
- None of FEAT-076/078's topology exists: group-scoped
  `<source>.<canonical-group>.retry` / `.dlq` topics, `X-Sol-Retry-At`,
  backoff with `jitter_ratio`, ack-only-after-durable-publish, and
  `Dead_letter` failing closed with no DLQ.
- `@sol/obs`'s `WorkerMessageStatus` (`{ok,error,retry,ack_failed}`)
  predates FEAT-076/078 too; `worker.ml` now also emits `dead_letter`,
  `relay_published`, `relay_failed`. A cross-language Grafana panel keyed
  on those statuses would silently miss a TS worker's retry/DLQ outcomes.

Consequence today: a TS worker and an OCaml `sol-worker` on the same topic
behave differently under failure, and a TS service cannot hand work to Sol's
retry/DLQ topics.

## Remediation

Spec references (read these, don't infer): `framework/sol-worker/sol-worker.md`
(contract, metrics, acknowledgement-ownership invariant),
`framework/kafka-eio-service/kafka-eio-service.md` (retry-topic mechanics),
`framework/kafka-eio-service/lib/kafka_service_retry_topics.ml` and
`kafka_service.ml` (naming, `X-Sol-Retry-At`, relay), plus DEC-021 /
FEAT-076 / FEAT-078.

1. **Outcome + declared capability in `@sol/kafka`.** Add a retry-capable
   consumer wrapper whose handler returns Sol's outcome (`Ack` /
   `Retry reason` / `Dead_letter reason`), mirroring `sol-worker`'s two-tier
   split: an Ack-only wrapper that cannot express `Retry`/`Dead_letter`, and
   a retry-capable one whose `retryStrategy` is **required** — no implicit
   `kafkajs` fallback. Pick the TS-idiomatic shape (discriminated union vs.
   result object) and keep the capability explicit.
2. **`retry_policy` vocabulary**, matching `sol-worker.md`: `baseDelayS`,
   `maxDelayS`, `maxAttempts` (maximum handler invocations including the
   initial one; negative = indefinite; `1` = no retry), `jitterRatio`.
   Backoff is `baseDelayS * 2^(attempt-1)`, jittered *before* the `maxDelayS`
   clamp; no generated delay exceeds `maxDelayS` or falls below 0. RNG
   injectable/seedable so tests are deterministic.
3. **`In_memory` and `Retry_topics` strategies.** `Retry_topics`: publish the
   raw record to the group-scoped `<source>.<canonical-group>.retry` topic
   and commit the original offset only after that publish succeeds; a relay
   consumer delays until `X-Sol-Retry-At` then re-runs the handler; on
   exhaustion or `Dead_letter`, move to `<source>.<canonical-group>.dlq`
   (with `X-Sol-Origin-Group`) and ack the retry offset only after that
   publish succeeds. Match `kafka_service_retry_topics.ml`'s
   canonical-group naming/sanitization exactly — a TS service and an OCaml
   service must agree on the topic name.
4. **Fail closed.** `Dead_letter` with no DLQ configured (i.e. `In_memory`)
   must never be acknowledged-and-discarded: leave the offset unacknowledged
   and treat it as terminal, per `sol-worker.md`'s acknowledgement-ownership
   invariant. Same for retry exhaustion.
5. **Complete `@sol/obs`'s status vocabulary:** add `dead_letter`,
   `relay_published`, `relay_failed` to `WorkerMessageStatus`, matching
   `worker.ml`.
6. **Demo coverage.** Move
   `examples/pluto/app/demo_ts/fulfillment_worker` to the retry-capable
   wrapper and exercise `Retry` (and DLQ on exhaustion), or record why a
   demo does not apply. Add the demo's Dockerfile to the
   `demo-ts-dockerfile-smoke` matrix if a new one appears.
7. **Cross-language proof.** A test that a TS-produced retry/DLQ record is
   byte-compatible with what the OCaml consumer expects (topic name,
   `X-Sol-Retry-At`, payload), and/or a live TS→OCaml retry round-trip.
   TS unit tests alone do not prove interop.
8. Fix `@sol/kafka`'s README doc nit from FEAT-080: the "traceparent helpers
   live here temporarily" non-goal is stale — they were moved/deduped in
   FEAT-038 and the package re-exports from `@sol/obs`.

## Non-goals

- Not a new Kafka client or general retry framework — `kafkajs` stays the
  transport.
- No retry-backend enum, no second broker, no Postgres-backed Kafka retry
  (FEAT-078 non-goals).
- Do not expose attempt/context to the handler unless separately specified —
  FEAT-078 deliberately left the handler signature unchanged.
- `Retry reason` is diagnostic text only; the runtime must never parse it for
  delay, routing, or retryability (FEAT-078).
- Not `sol-jobs` — FEAT-080's verdict is intentionally deferred.

## Acceptance criteria

- A TS worker's handler can return `Retry`/`Dead_letter`; the Ack-only form
  cannot express them; the retry-capable form requires `retryStrategy` with
  no implicit fallback.
- `In_memory` and `Retry_topics` share one `retry_policy`; backoff is
  jittered before the clamp and never exceeds `maxDelayS`; the RNG is
  injectable.
- `Retry_topics` uses group-scoped `<source>.<canonical-group>.retry`/`.dlq`
  naming identical to the OCaml side, sets `X-Sol-Retry-At`, and acks only
  after a durable publish succeeds.
- `Dead_letter`/exhaustion never ack without a durable destination
  (`In_memory` leaves the offset unacknowledged).
- `@sol/obs` `WorkerMessageStatus` includes `dead_letter`,
  `relay_published`, `relay_failed`.
- Broker-backed TS test (env-gated on `KAFKA_BROKERS`), plus the convention
  fixtures, demonstrate the real ownership transfer — not merely that kafkajs
  can produce/consume. (Corrected 2026-09-15: the original wording asked for a
  TS↔OCaml live interop test. Retry/DLQ is group-scoped and internal to the
  owning worker, so there is no cross-language hand-off to test — see DEC-022
  and the FEAT-080 reconciliation. What must match across languages is the
  *convention* — topic naming, headers, backoff — which the fixtures pin.)
- `demo_ts` exercises the retryable tier (or the exemption is recorded), and
  the stale README note is fixed.

## Completion notes (2026-09-15)

- `retry.ts` — retry policy + `backoffS` (mirrors kafka-eio's
  `Kafka.Consumer.backoff_s`, incl. the zero-jitter fast path), BUG-030
  group-scoped relay topic naming (sanitize + MD5 truncation), the `X-Sol-*`
  record-header builders, `parseAttemptHeader`/`parseRetryAtHeader`,
  `decideAction`.
- `outcome.ts` — `Ack | Retry reason | Dead_letter reason`; the reason is
  diagnostic text only.
- `routing.ts` — the *single* retry/DLQ routing decision, shared by the source
  path and the relay so they cannot drift.
- `retryable.ts` — `wrapEachRetryableMessage`: declared capability
  (retry-topics requires a relay and `maxAttempts >= 1` at construction, so a
  missing destination is a construction error), `in-memory` sleep/re-run,
  retry-topics forward-then-commit, fail-closed.
- `relay.ts` — transport only: `provisionRelayTopics`, `kafkaRetryRelay`,
  `runRetryRelayConsumer` (group `<group>-sol-retry`). Publish-before-commit;
  a failed publish throws (input uncommitted); an undecodable retry record is
  transferred to the DLQ before commit; malformed retry metadata is
  deliberately terminal (documented as policy, not arithmetic).
- `@sol/obs` — `WorkerMessageStatus` gained `dead_letter`,
  `relay_published`, `relay_failed`.
- `demo_ts/fulfillment_worker` — migrated onto the retryable API; the app
  expresses outcomes and policy only, never headers/topics/offsets.

**Tests:** 42 `@sol/kafka` unit + 12 `@sol/obs` (3 broker tests skipped with no
broker); 45/45 with `KAFKA_BROKERS=localhost:9092` against Redpanda. CI skips
the integration trio (the `test` job has no broker), matching `run_kafka()`.

**Demo/example coverage:** satisfied — `demo_ts/fulfillment_worker` migrated
to the retryable tier, exercising the API end to end.

**Language-parity impact:** this *is* the `@sol/kafka` retry/DLQ parity; the
remaining `-fn`/`sol-jobs` verdicts are tracked in FEAT-080.

If implementation shows this is too large for one PR, split item 5 (the
`@sol/obs` vocabulary change) out as its own small ticket rather than growing
this one.
