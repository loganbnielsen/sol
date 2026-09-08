---
id: CODEX_STYLE_AUDIT-010
type: refactor
severity: high
source: style audit
branch: CODEX_STYLE_AUDIT-010/flatten-kafka-register
worktree: ../sun-CODEX-010
---

Flatten Kafka service registration into a Result pipeline.

**Depends on:** none.

**Problem:** `integrations/kafka/kafka-eio-service/lib/kafka_service.ml:54-84`
checks partition guards, topic creation, schema registration, and compatibility
through nested `match` blocks. The function returns `Result`, but does not use a
linear bind style.

**Goal:** Make the successful registration path clear and make error propagation
consistent.

**Acceptance criteria:**

- Introduce a local `let* = Result.bind` or reuse an existing helper.
- Refactor `register` so each step is one sequential binding.
- Keep the compatibility-setting warning non-fatal.
- Add or update a unit test around a failing intermediate step if test harnesses
  already support it.

## Review — automated checks passed
register refactored into a flat Result pipeline with local let* binding; compatibility warning preserved as non-fatal; build clean, all 14 tests pass, only target file changed
