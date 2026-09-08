---
id: CODEX_STYLE_AUDIT-031
type: refactor
severity: high
source: style audit
branch: codex/style-audit-031
worktree: /home/lbendtly/Code/sun-CODEX-031
---

Reject Prometheus metric family kind conflicts instead of ignoring them.

**Depends on:** none.

**Problem:** `integrations/observability/obs-eio-prometheus/lib/obs_prometheus.ml:59-96`
creates metric families by name, but if a later event uses the same name with a
different kind the code matches `_ -> ()` and silently drops the metric.

**Goal:** Make metric family kind conflicts visible and type-safe.

**Acceptance criteria:**

- Track the registered metric kind for each metric name.
- Return or log a clear error when the same name is used as counter, gauge, and
  histogram inconsistently.
- Add tests for conflicting metric kinds.

## Review — automated checks passed

Focused Prometheus tests pass. Metric family conflicts now log a clear error and
drop the conflicting event instead of silently ignoring it. Tests cover
counter/gauge/histogram conflict combinations.
