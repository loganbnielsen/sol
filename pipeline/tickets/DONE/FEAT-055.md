---
id: FEAT-055
type: feature
severity: low
source: verification 2026-09-11 — deploy/runtime visibility is largely already built; this is the one real gap
premise: "test $(rg -l Sol_cli_run_log cli/sol/bin/cmd_up.ml cli/sol/bin/cmd_deploy.ml 2>/dev/null | wc -l) -eq 2"
---

**Depends on:** None.

**Premise probe (INFRA-010):** the `premise:` above succeeds when this work is *done*, so once the run log is wired into both deploy paths the pipeline will report `premise-stale` instead of `actionable` and nobody has to remember to re-read this ticket. It currently reports `holds` — `Sol_cli_run_log` is used only by `cmd_cloud_tf.ml` and its test, so neither `sol up` nor `sol deploy` has it yet. This is the mechanism's first use, and the reason it is here: four findings were closed on 2026-09-11 as already-built, and this ticket was filed in the same pass.

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

## Completion notes

Landed 2026-09-12. The `premise:` probe above now reports **premise-stale** by
design — it succeeds once both `cmd_up.ml` and `cmd_deploy.ml` mention
`Sol_cli_run_log`, which is exactly what this change did.

- `Sol_cli_run_log` gained a second phase kind. `run_phase` already covered a
  single subprocess; `run_task` covers the deploy path's phases (the executor,
  the build/apply loop) whose output is a `(unit, string) result`. Both share
  one `finish_phase`, so there is still exactly one run-log implementation, and
  `cmd_cloud_tf.ml` is untouched.
- `format_failure_report` now prints the **run id** as well as the log path and
  tail, which is what makes a deploy recoverable after the terminal is gone.
- `sol up` and `sol deploy` create a run (`up-…` / `deploy-…`) before doing any
  work, print `Run: …` and its directory, record the rendered plan summary to
  `plan.log`, and wrap the mutating phase (`apply`/`dry-run`/`emit`) so a
  failure lands a `apply.log` with the full error detail and prints the run id,
  path and tail. Pruning is inherited from `create`.

On the "full log" wording in Scope: the phase log holds the plan the command
acted on and, on failure, the propagated error string — which already includes
the failing subprocess's stderr (`Sol_cli_process.error_to_string` prints
`Non_zero … : stderr`), and docker/kubectl write their diagnostics to stderr.
So a failed build or apply is recoverable from the log. Live progress stays on
the terminal, as the ticket requires.

Verified end to end with a scaffolded workspace: `sol up --dry-run` printed
`Run: up-…` and wrote `.sol/runs/up-…/{plan.log,dry-run.log}`, with `plan.log`
holding the rendered plan summary. The full `cli/sol/test` suite passes,
including a new `format_failure_report` test asserting the run id is named.

Demo/example coverage: the CLI surface is unchanged (no new flags or commands);
the run directory is created for the existing `sol up`/`sol deploy`, which the
`golden-path-smoke` job already runs.
