---
id: REFAC-025
type: refactor
severity: low
source: codebase simplification review 2026-06-15
branch: REFAC-025/metric-registration-helper
worktree: /home/lbendtly/Code/sun-REFAC-025-metric-registration-helper
---

Extract metric registration boilerplate repeated across all three framework modules

**Depends on:** None.

**Description:**

`sun-svc`, `sun-worker`, and `sun-fn` each register a counter + histogram pair at startup with the same two-call pattern:

| File | Lines | Counter name | Histogram name |
|------|-------|-------------|----------------|
| `framework/sun-svc/lib/service.ml` | 171–179 | `sun_http_requests_total` | `sun_http_request_duration_seconds` |
| `framework/sun-worker/lib/worker.ml` | 58–66 | `sun_worker_messages_total` | `sun_worker_message_duration_seconds` |
| `framework/sun-fn/lib/fn.ml` | 49–56 | `sun_fn_invocations_total` | `sun_fn_invocation_duration_seconds` |

Each does:
```ocaml
let c = Obs.register_counter o
  ~name:"..." ~help:"..." ~label_names:[...] in
let h = Obs.register_histogram o
  ~name:"..." ~help:"..." ~label_names:[...] in
(c, h)
```

Only the metric names, help strings, and label name lists differ. A helper that takes these as arguments would reduce each registration site to one call.

**Remediation:**

Add to `integrations/observability/obs-eio/lib/obs.ml` (or a new `obs_framework.ml`):

```ocaml
val register_counter_and_histogram :
  t ->
  counter_name:string -> counter_help:string -> counter_labels:string list ->
  histogram_name:string -> histogram_help:string -> histogram_labels:string list ->
  counter * histogram
```

Replace the three inline pairs in `service.ml`, `worker.ml`, and `fn.ml` with a single call each.

**Acceptance criteria:**

- Each of `service.ml`, `worker.ml`, and `fn.ml` contains at most one `Obs.register_counter` and one `Obs.register_histogram` call (via the helper).
- `dune build` passes.
- `dune test framework/` passes.
