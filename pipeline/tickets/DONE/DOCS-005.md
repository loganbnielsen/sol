---
id: DOCS-005
type: docs-finding
severity: critical
source: project/audits/2026-06-22_docs_audit.md
branch: DOCS-005/stale-sun-worker-spec
worktree: ../sun-DOCS-005-stale-sun-worker-spec
---

`sun-worker.md` WORKER module type and Make(W).run signature are both stale

**Description:** `framework/sun-worker/sun-worker.md` documents the `WORKER` module type with `handle : Message.t -> ack:(unit -> unit) -> (unit, string) result`. The actual `worker.mli` signature is `handle : Message.t -> ack:(unit -> unit) -> trace_ctx:Obs_trace.t option -> (unit, string) result`. Code implementing `WORKER.handle` from the spec will not compile.

The spec also documents `Make(W).run` with only `env`, `config`, and `?ot`. The actual `.mli` additionally accepts `?on_ready:(unit -> unit)`, `?stop:bool Atomic.t`, `?max_messages:int`, and `?retry_strategy`. These four parameters are entirely absent from the spec.

**Impact:** Any user implementing a worker from the spec will get a type mismatch on `handle`. The missing run parameters mean users cannot discover graceful stop, message limits, or retry strategy configuration without reading the `.mli` directly.

**Remediation:**
1. Update the `WORKER` module type section to add `~trace_ctx:Obs_trace.t option` to `handle`.
2. Update the `Make(W).run` section to show all six parameters with brief descriptions.
3. Add a short section documenting `retry_strategy` (the `In_memory` vs `Retry_topics` ADT) since it is now a user-configurable type.

## Review — automated checks passed
All remediation items verified: trace_ctx added to WORKER.handle, Make(W).run documents all 5 optional params, retry_strategy section added, no stale signatures remain, project/tickets/ untouched.
