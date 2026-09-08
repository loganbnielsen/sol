---
id: CODE_LAYER-007
type: bug
severity: low
source: project/audits/2026-09-06_code_layer_audit.md
branch: CODE_LAYER-007/shared-dashboard-json
worktree: ../sun-CODE_LAYER-007-shared-dashboard-json
pr: https://github.com/loganbnielsen/sun/pull/128
---

**Depends on:** None.

## Problem

The four Grafana dashboards Sun ships (`workspace-overview`,
`domain-overview`, `service-template`, `release-timeline`) exist as real
files under `platform/infra/base/dashboards/*.json`, loaded by
`platform/infra/base/main.tf`'s `kubernetes_config_map.grafana_dashboards`
via `file(...)`. `cmd_dev.ml`'s `install_local_grafana_config` instead
applies dashboards from four separate OCaml string literals in
`cli/sun/lib/sun_cli_dev_observability.ml`
(`workspace_overview_json`, `domain_overview_json`, `service_template_json`,
`release_timeline_json`).

A byte-for-byte diff of both copies confirms they are currently identical.
But unlike the Alloy config (CODE_LAYER-006), there is no comment anywhere
in either file flagging that these must be kept in sync — the next dashboard
panel edit made against the `.json` files (the natural place to edit a
Grafana dashboard) will silently leave `sun dev up`'s Grafana on the old
version with no warning at all.

## Goal

`sun dev up` and `platform/infra/base` show the same Grafana dashboards
because they read the same files, not because two copies happen to agree
today.

## Remediation

Delete the four `*_json` string-literal bindings in
`sun_cli_dev_observability.ml`. Have `cmd_dev.ml` read
`platform/infra/base/dashboards/*.json` directly from the Sun monorepo
checkout — `cmd_cloud_tf.ml` already resolves that root via
`Sun_cli_cmd_new.infer_sun_home` for the equivalent "read a file that ships
with the Sun checkout" need (locating `platform/infra/<provider>/`); reuse
the same resolution here instead of embedding a second copy of the JSON.

## Acceptance criteria

- `sun_cli_dev_observability.ml` no longer contains dashboard JSON as OCaml
  string literals.
- `sun dev up`'s dashboard ConfigMap is built from
  `platform/infra/base/dashboards/*.json` directly.
- A fresh `sun dev up` still installs all four dashboards into Grafana
  (verified via the sidecar-loaded ConfigMap or the Grafana UI/API).
- Focused tests pass in `cli/sun`.

## Perf-gate sign-off (2026-09-06)

Merged (PR #128, commit `c85983f`). Fourth occurrence in one session of
the same false-alarm pattern (CODE_LAYER-009, CODE_LAYER-005,
CODE_LAYER-006): post-merge gate flagged e2e at 1.904s vs. 1.188s
baseline (1.60x); automatic revert failed on a dirty
`tools/perf/perf_baseline.json`, so the merge stands and only the
ticket-state transition was blocked. Immediately re-ran `bash
platform/local/scripts/run_tests.sh` with no other change: e2e came back
at 1.188s, exactly the baseline. Signing off as a flake — moving to
DONE. Given this has now happened four times, the merge step's own perf
run picking up transient machine contention (rather than something
inherent to any of these diffs) looks like the real explanation; worth a
ticket of its own if it keeps recurring.
