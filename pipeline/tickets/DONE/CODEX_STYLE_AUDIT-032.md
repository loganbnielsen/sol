---
id: CODEX_STYLE_AUDIT-032
type: refactor
severity: medium
source: style audit
branch: CODEX_STYLE_AUDIT-032/validate-prometheus-names
worktree: /home/lbendtly/Code/sun
---

Validate observability metric and label names before rendering.

**Depends on:** none.

**Problem:** `Obs.metric_event` and Prometheus rendering accept `name` and label
keys as raw strings. `obs_prometheus.ml:151-169` concatenates them directly into
Prometheus exposition format.

**Goal:** Use refined metric and label names so invalid output cannot be emitted.

**Acceptance criteria:**

- Add constructors for metric names and label names that validate Prometheus
  naming rules.
- Use validated names in `Obs.register_counter`, `register_gauge`, and
  `register_histogram`.
- Update tests for invalid names and existing valid metrics.

## Review — automated checks passed
CODEX_STYLE_AUDIT-032 passes review. The branch adds public metric_name and label_name validators for Prometheus naming rules, calls them from register_counter/register_gauge/register_histogram before returning emitters, and adds coverage for valid names plus invalid metric and label names. Pre-commit on the branch passed build, unit, observability, storage, kafka, and e2e suites; the feature commit is scoped to obs-eio code/tests with no perf baseline reset.
