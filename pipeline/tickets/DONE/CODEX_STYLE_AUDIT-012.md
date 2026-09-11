---
id: CODEX_STYLE_AUDIT-012
type: refactor
severity: medium
source: style audit
branch: CODEX_STYLE_AUDIT-012/typed-retry-actions
worktree: ../sun-CODEX-012
---

Clarify Kafka retry-topic outcomes with typed actions.

**Depends on:** CODEX_STYLE_AUDIT-011.

**Problem:** `integrations/kafka/kafka-eio-service/lib/kafka_service_retry_topics.ml`
mixes handler result matching, DLQ/retry topic selection, delayed publishing, and
ack decisions in deeply nested branches around `decode_retry` and
`decode_and_handle`.

**Goal:** Represent retry handling decisions as a small variant and execute them
in one place.

**Acceptance criteria:**

- Introduce a typed action such as `Continue`, `Stop`, `Retry of ...`, or
  `Dlq of ...`.
- Keep `publish_raw` and `ack` side effects at the edge.
- Remove duplicated target/delay selection logic for first and subsequent
  attempts.
- Preserve partition pause/resume behavior.

## Review — automated checks passed
review passed
