---
id: CODEX_STYLE_AUDIT-013
type: refactor
severity: medium
source: style audit
branch: CODEX_STYLE_AUDIT-013/result-config-builders
worktree: ../sun-CODEX-013
---

Replace mutable first-error configuration builders with Result folds.

**Depends on:** none.

**Problem:** `integrations/kafka/kafka-eio-producer/lib/kafka_producer.ml:35-57`
and `integrations/kafka/kafka-eio-consumer/lib/kafka_consumer.ml:51-74` build
librdkafka configs by mutating `first_err`. This is a manual Result pipeline
that requires readers to reason about mutation and short-circuiting.

**Goal:** Make Kafka config application a typed, linear error pipeline.

**Acceptance criteria:**

- Replace `first_err` mutation with a Result-returning `set` and `List.fold_left`
  or monadic bindings.
- Keep all config keys and values unchanged.
- Share helper code between producer and consumer if that reduces duplication
  without coupling unrelated behavior.

## Review — automated checks passed
review passed
