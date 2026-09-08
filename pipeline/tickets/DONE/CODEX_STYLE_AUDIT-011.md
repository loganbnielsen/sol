---
id: CODEX_STYLE_AUDIT-011
type: refactor
severity: high
source: style audit
branch: CODEX_STYLE_AUDIT-011/kafka-decode-pipeline
worktree: ../sun-CODEX-011
---

Extract and flatten Kafka decode pipelines.

**Depends on:** none.

**Problem:** Kafka message decoding repeats nested `decode_wire`, JSON parsing,
domain decode, and handler dispatch in multiple places:

- `integrations/kafka/kafka-eio-service/lib/kafka_service.ml:123-143`
- `integrations/kafka/kafka-eio-service/lib/kafka_service.ml:168-188`
- `integrations/kafka/kafka-eio-service/lib/kafka_service_retry_topics.ml:85-106`
- `integrations/kafka/kafka-eio-service/lib/kafka_service_retry_topics.ml:149-170`

**Goal:** Make decoding a reusable Result pipeline and keep retry/ack behavior
separate from parsing.

**Acceptance criteria:**

- Extract a helper that returns decoded message plus trace context or a typed
  decode error.
- Use Result combinators or monadic binding instead of nested matches.
- Share the helper across normal, partitioned, and retry-topic consumers.
- Preserve existing `on_decode_error` strings or document intentional wording
  changes in tests.

## Review — automated checks passed
decode_message helper correctly extracted into kafka_service_schema.ml; all four repeated decode pipelines replaced; build and tests green
