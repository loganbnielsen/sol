---
id: AUDIT-084
type: audit-finding
severity: low
title: sol target misreports configuration failures as definite "not configured"
source: internal/pipeline/audits/2026-10-02_error_collapse_audit.md
---

sol target misreports configuration failures as definite "not configured"

**Depends on:** None.

## Problem

Two reads in `cli/bin/cmd_target.ml` collapse a failure into a definite
known-negative:

- `kubernetes_status` maps **any** `Sol_cli_config.destination_of_target` error
  to `Sol_cli_target_report.Not_configured`, whose description says the target
  "names no kube_context". The only other cause — the target resolves to
  `k3d-sol-local`, a reserved execution mode — carries a very actionable
  message ("use `sol local <command>` … point this target at a cluster you
  own") that is discarded. `substrate_status` then reports it as the definite
  `Unmet "the target declares no explicit Kubernetes destination"`.
- `available_target_paths` maps a workspace load/parse failure to `[]`, so
  `available_targets ()` prints "no targets found: declare them in
  sol/environments.yml" when the workspace could not be read at all.

## Impact

A misconfiguration (or a workspace that failed to load) is presented as a
missing declaration, sending the operator to edit `sol/environments.yml` /
`kube_context` instead of fixing the actual cause. Related to the class fixed in
`sol_cli_status` and DEC-040: a failed observation must not become a definite
negative.

## Remediation

Carry the reason. For `kubernetes_status`, add a status that names the failure
(or reuse the existing `Unreadable (context, reason)` shape) rather than
`Not_configured`, and describe it in `Sol_cli_target_report.describe`. For
`available_target_paths`, keep the `result` of `Sol_cli_workspace_model.load_cwd`
and print the load error when the list is empty because the load failed.

## Acceptance criteria

- A target whose destination resolves to the reserved local context reports that
  refusal, not "names no kube_context".
- A workspace that fails to load reports the load error, not "no targets found".
- A target that genuinely names no `kube_context` still reports
  `Not_configured` with the existing guidance.
- `test_target_report` covers the new description.

**Demo/example coverage:** Not applicable — CLI target diagnostics; no
app-author surface.

**TypeScript-parity note (DEC-022):** No language-parity impact — target
reporting in the OCaml CLI.
