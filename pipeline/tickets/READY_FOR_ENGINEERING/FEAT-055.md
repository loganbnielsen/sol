---
id: FEAT-055
type: feature
severity: low
source: verification 2026-09-11 — deploy/runtime visibility is largely already built; this is the one real gap
---

**Depends on:** None.

Wire the run log into the deploy path, so `sol up` and `sol deploy` produce a run ID and keep their diagnostics on disk instead of only in the terminal that ran them.

## Why this is the only item still missing

A verification pass over the four items the ROADMAP listed as "not yet ticketed" found three already implemented:

- **Kubernetes-derived diagnosis in `sol status`** — implemented (`Sol_cli_status.service_diagnoses_named` calls `Sol_cli_rollout_diagnosis.diagnose_service_live`), from OBS-001.
- **`sol logs` → `kubectl` runtime fallback** — implemented: `fallback_to_kubectl` triggered on `Sol_cli_loki.classify_process_error` (timeout, connection, other), at five call sites.
- **Pod-stdout collection in the cluster** — implemented, and with **Alloy** rather than promtail: `cli/platform/infra/base/alloy/logs.alloy.tftpl` runs `discovery.kubernetes "pods"` + `loki.source.kubernetes`, tailing each pod's logs through the Kubernetes API rather than relying on app-pushed lines.

`Sol_cli_run_log` exists — run IDs, per-phase logs, pruning policy — but its only caller is `cmd_cloud_tf.ml` (terraform init/plan/apply/destroy). `sol up` and `sol deploy` create no run log, so a deploy's diagnostics live only in the terminal that ran it, which is precisely what the three-layer model ruled out.

## Scope

- Create a run log at the start of `sol up` and `sol deploy`, keyed by a run ID, with per-phase output under `.sol/runs/<run-id>/`.
- Print the run ID and the log path when a phase fails, so the full log is recoverable after the terminal is closed.
- Reuse `Sol_cli_run_log` rather than adding a second mechanism, and inherit its pruning policy.
- Leave the compact live progress output as it is: the log is for afterwards, not instead of.

## Acceptance criteria

- `sol up` and `sol deploy` write a per-run log under `.sol/runs/`, identified by a printed run ID.
- A failing phase prints the run ID and the path to its log.
- The run-log directory stays bounded by the existing pruning policy.
- One run-log implementation: the deploy path and `cmd_cloud_tf.ml` share it, and no second one is introduced.
