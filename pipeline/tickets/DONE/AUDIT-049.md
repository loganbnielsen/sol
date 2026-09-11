---
id: AUDIT-049
type: audit-finding
severity: high
source: codebase review 2026-06-14
branch: AUDIT-049/kafka-partition-backpressure
worktree: /home/lbendtly/Code/sun-AUDIT-049-kafka-partition-backpressure
---

Bound per-partition Kafka consumer queues and apply backpressure

**Depends on:** None.

**Description:** `integrations/kafka/kafka-eio-consumer/lib/kafka_consumer.ml` creates per-partition streams with:

```ocaml
let stream = Eio.Stream.create max_int
```

This is inside `consume_partitioned`, so a slow handler or long retry delay can let the routing loop enqueue an effectively unbounded number of messages for one partition.

**Impact:** A lagging partition can consume unbounded memory and hide backpressure from librdkafka. The code does pause a partition during retry sleep, but messages already routed to the per-partition stream can grow without a practical cap, especially when handler latency is high or broker fetches arrive faster than processing.

**Remediation:**

1. Replace `max_int` with a configurable bounded queue size, with a conservative default.
2. When a partition queue is full, backpressure the routing loop or pause/resume that partition until capacity is available.
3. Add observability for queue depth or backpressure events if the existing metrics layer can support it cleanly.
4. Add tests that simulate a slow per-partition handler and verify memory-safe bounded behavior.

**Acceptance criteria:**

- `consume_partitioned` no longer allocates streams with `max_int` capacity.
- A slow handler cannot enqueue more than the configured per-partition limit.
- Tests cover queue saturation and prove messages are still processed in partition order.
- Existing Kafka integration tests continue to pass.

## Review — automated checks passed
Bounded per-partition Kafka consumer queues implemented with configurable depth (default 64), natural backpressure via Eio.Stream blocking, optional obs gauge, and two new Quick unit tests covering queue saturation and metrics path.
