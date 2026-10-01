---
id: FEAT-117
type: feature
severity: medium
source: BUG-099 (Part B, the event contract)
title: "TypeScript parity: declare a topic's partition count and message key"
---

TypeScript parity: declare a topic's partition count and message key

**Depends on:** None.

## Problem

BUG-099 made an event's partition count and message key part of the framework
contract in OCaml — `Kafka_service.MESSAGE.partitions` and `MESSAGE.key`, with Sol
creating the topic at the declared count, `publish` sending the declared key, and
retry and DLQ topics inheriting the count
(`internal/specs/framework-conventions.md` § Partitioning and key).

The TypeScript framework has no equivalent. `@sol-fab/kafka` — an external npm
package, which is why this is a tracking ticket rather than an in-repo change —
registers a topic by name (`registerTopic({ topicName, … })`) and provisions relay
topics from the source topic alone (`provisionRelayTopics({ sourceTopic, groupId })`),
as `examples/pluto/app/demo_ts/` shows. A TypeScript producer therefore cannot
declare how many partitions its topic has, and cannot key its records, so
per-entity ordering does not survive more than one partition for a TS
application.

DEC-022 makes this a recorded verdict rather than silent drift: the capability
now exists in one first-class language and is absent in the other.

## Remediation

`@sol-fab/kafka` gains the equivalent contract — a declared partition count the
topic is created with and never reduced, inherited by retry and DLQ topics, and a
declared message key that published records are keyed by — so a TypeScript
application holds the same resolution as an OCaml one.

## Acceptance criteria

- The TS golden path (`examples/pluto/app/demo_ts/`) declares a partition count
  and a key for its event topic.
- A TS test on a multi-partition topic shows same-key records processed in order
  by one consumer, matching the OCaml integration test BUG-099 added.
- `internal/specs/framework-conventions.md` § Partitioning and key holds for both
  languages, and the capability matrix records the verdict as implemented.

## Completion notes (2026-10-01)

**Premise re-verified (2026-10-01):** part A had landed the golden path's declaration
(`examples/pluto/app/demo_ts` passed `partitions: 3` and keyed its `producer.send`), but
`@sol-fab/kafka` itself had no contract: `registerTopic` took loose options, `provisionRelayTopics`
defaulted the relay partition count to 1 instead of inheriting the source topic, and there was
no declared key a publish path applied. The `internal/specs/framework-conventions.md`
§ Partitioning and key obligation ("the same resolution holds for an OCaml event module and a
TypeScript one") was therefore unmet on the TypeScript side.

### Part B — `@sol-fab/kafka` (external repo, `loganbnielsen/sol-kafka`)

Landed as PR #2 (`3956fea`), released as **`@sol-fab/kafka@0.3.0`** (tag `v0.3.0`, OIDC
trusted publish, provenance):

- `TopicContract<T>` declares a topic's name, schema, partition count and
  `key: (message: T) => string | undefined` — the TypeScript `MESSAGE`.
- `registerTopic({ contract })` provisions at the declared count, rejects a count below 1
  before any broker call, and refuses to reduce an existing topic below its live count
  (`Kafka_service.register`'s `Config` / `Partition_count_reduction` parity).
- `publish(producer, topic, message)` wire-encodes with the registered schema id and keys the
  record with the declared key (`Kafka_service.publish` parity).
- `provisionRelayTopics({ source, groupId })` inherits the source topic's partition count from
  the broker (falling back to the declaration before the source exists), so retry/DLQ records
  keep their key → partition mapping and a TS worker can inherit the shape of a topic an OCaml
  service created.
- `describeTopic` exposes what the broker actually has (`Admin.query_topic_partitions` parity),
  listing names first so a not-yet-created topic is quiet rather than a kafkajs ERROR log.

Validation: `npm run build`; `npm test` (55 pass / 4 skip); broker-backed
`KAFKA_BROKERS=localhost:9092 SCHEMA_REGISTRY_URL=http://localhost:8081 npm test` (59 pass). The
new multi-partition ordering test is **mutation-checked**: with the declared key removed from
`publish`, it fails on `one member handled every record for alpha` (actual 2), so it detects the
absence of keying rather than merely exercising the field. The `broker` CI job now exposes
Redpanda's schema registry and sets `SCHEMA_REGISTRY_URL` so that test runs on the PR gate.

### Sol side

`examples/pluto/app/demo_ts` adopts the contract: `order_svc` declares `ORDER_PLACED:
TopicContract<OrderPlaced>` (3 partitions, key `order_id`) and publishes through it; the
`fulfillment_worker` passes the source shape to `provisionRelayTopics` and lets the live topic
supply the count. Both units pin `@sol-fab/kafka@^0.3.0` and the demo's `package-lock.json`
resolves 0.3.0; `npm ci && npm run build -w order-svc -w fulfillment-worker` typechecks.

### Acceptance mapping

| Criterion | Evidence |
|---|---|
| The TS golden path declares a partition count and a key for its event topic | `examples/pluto/app/demo_ts/order_svc/src/index.ts` — `ORDER_PLACED` with `partitions: 3`, `key: (order) => order.order_id`; the unit publishes through `publish(...)` |
| A TS test on a multi-partition topic shows same-key records processed in order by one consumer | `sol-kafka` `test/partitioning.integration.test.ts` (mirrors BUG-099's OCaml case); mutation-checked as above |
| `internal/specs/framework-conventions.md` § Partitioning and key holds for both languages, and the capability matrix records the verdict as implemented | the convention already stated the two-language obligation; the matrix's verdict table (`internal/pipeline/dogfood/2026-09-07_typescript_demo_spike.md` → Addendum → Verdicts) gains a **Declared partitioning + message key** row marked *implemented (FEAT-117 part B, 2026-10-01)* |

**Demo/example coverage:** the runnable example (`examples/pluto/app/demo_ts`) is updated in
the same change, as the rule requires.

**TypeScript parity (DEC-022):** this ticket *is* the TypeScript half of the partition/key
capability; the verdict is now recorded as implemented in both languages.
