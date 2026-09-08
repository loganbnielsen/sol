---
id: AUDIT-025
type: audit-finding
severity: low
source: project/audits/2026-06-11_audit.md
branch: AUDIT-025/decode-error-structured-log
worktree: ../sun-AUDIT-025-decode-error-structured-log
---

`default_on_decode_error` uses unstructured stderr; callback lacks raw bytes

**Depends on:** None.

**Description:** Two gaps in decode-error observability (`integrations/kafka/kafka-eio-service/lib/kafka_service.ml` lines 337–340):
1. `default_on_decode_error` uses `Printf.eprintf` (unstructured stderr) — decode errors are invisible in Loki when no custom handler is supplied.
2. The `on_decode_error` callback signature (`string -> ack:(unit -> unit) -> handler_result`) receives only the error string, not the raw message bytes — users cannot forward the failing payload to a dead-letter topic from this callback.

**Impact:** Silent decode errors in Loki dashboards. No out-of-box dead-letter forwarding.

**Remediation:** (1) Add `?ot:Obs.t` to `default_on_decode_error` and emit a structured log line via `Obs.log_t` when the handle is available. (2) Extend the callback signature to pass `raw_bytes:bytes` alongside the error string (API break — bump the module version and update all callers).

## Review — automated checks passed
All remediation items implemented: raw_bytes parameter added to on_decode_error signature and all call sites, structured Obs.log_t emitted in both consume and consume_partitioned wrappers, decode_retry path updated, .mli updated, integration test updated, build clean.
