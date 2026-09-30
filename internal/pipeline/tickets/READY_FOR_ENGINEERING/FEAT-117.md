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
