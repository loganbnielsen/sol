---
id: CODEX_STYLE_AUDIT-026
type: refactor
severity: medium
source: style audit
branch: CODEX_STYLE_AUDIT-026/explicit-kafka-security-protocol
worktree: /home/lbendtly/Code/sun
---

Make Kafka security protocol parsing explicit instead of defaulting unknown values.

**Depends on:** none.

**Problem:** `integrations/kafka/kafka-eio-core/lib/kafka_security.ml:27-34`
parses `KAFKA_SECURITY_PROTOCOL`, but any unknown value silently falls back to
`Plaintext`.

**Goal:** Treat security protocol as a finite domain with parse failures.

**Acceptance criteria:**

- Add `protocol_of_string : string -> (protocol, string) result`.
- Change env parsing to surface unknown protocol values instead of silently using
  plaintext.
- Update producer/consumer config creation to handle the parse error clearly.

## Review — automated checks passed
CODEX_STYLE_AUDIT-026 passes review. The branch adds protocol_of_string with explicit finite Kafka security protocol parsing, changes Kafka_security.of_env to return a Result for unknown KAFKA_SECURITY_PROTOCOL values, and keeps Kafka_service.config_of_env as a convenience boundary that raises a clear Invalid_argument at startup. Producer/consumer config creation still surfaces Kafka_security.apply errors through Result. Focused Kafka security/service tests and dune build pass; branch pre-commit passed build, unit, observability, storage, kafka, and e2e suites. Diff is scoped to Kafka security/config code and tests.
