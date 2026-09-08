---
id: REFAC-042
type: refactor
severity: high
source: codebase simplification review 2026-06-16
branch: REFAC-042/extract-decode-pipeline
worktree: ../sun-REFAC-042-extract-decode-pipeline
---

Extract duplicated 3-stage decode pipeline in `kafka_service`

**Depends on:** None.

**Description:**

The three-stage wire-decode pipeline (decode_wire → `Yojson.Safe.from_string` → `topic.decode` → handler) is copy-pasted four times across two files:

- `kafka-eio-service/lib/kafka_service.ml` lines 126–141 (standard consume path)
- `kafka-eio-service/lib/kafka_service.ml` lines 171–186 (partitioned In_memory branch)
- `kafka-eio-service/lib/kafka_service_retry_topics.ml` lines 80–98 (`decode_retry` inner function)
- `kafka-eio-service/lib/kafka_service_retry_topics.ml` lines 144–163 (`decode_and_handle` outer function)

Each copy independently handles `on_decode_error` for the same three error cases (`""`, `"json parse: ..."`, `"message decode: ..."`). A bug fix, new tracing annotation, or change to error format must be applied to all four sites.

**Remediation:**

1. Extract a single private function, e.g.:
   ```ocaml
   let decode_message topic ~on_decode_error ~raw_bytes ?attempt handler
   ```
   that runs all three decode stages and calls `on_decode_error` on failure or `handler` on success. The `?attempt` optional argument defaults to `0` and is used by the retry path for context.
2. Place it in a new `kafka-eio-service/lib/kafka_service_decode.ml` module (and expose it in `kafka_service_intf.ml` if needed across files).
3. Replace all four call sites.

**Acceptance criteria:**

- `grep -n "on_decode_error" integrations/kafka/kafka-eio-service/lib/kafka_service.ml` returns at most 2 lines (the function definition and one call site).
- `dune build` and `dune test integrations/kafka/` pass.

## Review — automated checks passed
3-stage decode pipeline correctly extracted into kafka_service_decode.ml; all 4 call sites replaced; build and tests pass

## Review — automated checks passed
3-stage decode pipeline correctly extracted into kafka_service_decode.ml; all 4 call sites replaced; build and tests pass
