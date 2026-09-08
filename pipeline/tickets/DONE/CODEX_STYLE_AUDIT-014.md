---
id: CODEX_STYLE_AUDIT-014
type: refactor
severity: high
source: style audit
branch: CODEX_STYLE_AUDIT-014/labeled-ffi-calls
worktree: ../sun-CODEX-014
---

Label unsafe positional Kafka raw FFI calls.

**Depends on:** none.

**Problem:** `integrations/kafka/kafka-eio-core/lib/kafka_raw.mli:78-79` exposes
raw signatures such as `create_topic : kafka_handle -> string -> int -> int ->
int` and `commit_message : kafka_handle -> string -> int32 -> int64 -> bool ->
...`. These are high-risk positional APIs crossing an FFI boundary.

**Goal:** Make raw Kafka calls hard to misuse from OCaml code.

**Acceptance criteria:**

- Wrap or replace public raw functions with labeled arguments such as
  `~topic`, `~partition`, `~offset`, and `~async`.
- Update producer/consumer call sites, especially commits in
  `kafka_consumer.ml`.
- Keep the C stubs unchanged unless necessary; the OCaml binding can provide the
  safer surface.

## Review — automated checks passed
review passed
