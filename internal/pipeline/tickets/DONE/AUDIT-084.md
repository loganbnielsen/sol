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

## Completion notes

Fixed 2026-10-02, `AUDIT-084/target-config-failure`.

- `Sol_cli_target_report.kubernetes_status` gained `Misconfigured of
  (context, reason)`. `cmd_target.ml`'s `kubernetes_status` now splits the
  `destination_of_target` error by the target's own typed input: a blank
  `kube_context` stays `Not_configured` (known-negative), anything else is
  `Misconfigured` carrying the reason — the reserved-local refusal and its
  `sol local <command>` guidance is no longer discarded. `describe` redacts the
  named context by default and shows it under `--verbose` (DEC-020);
  `substrate_status` reports it as `Unmet <reason>` rather than
  "declares no explicit Kubernetes destination".
- The same fold in `platform_status` (the third `destination_of_target` read in
  that file, not named in the ticket) is fixed the same way: the readiness row
  now carries the reason instead of a generic "no explicit Kubernetes
  destination".
- `available_targets` keeps the `load_cwd` result: a workspace read failure
  prints "the workspace could not be read, so its targets are unknown: <error>"
  instead of "no targets found".
- Tests: `test_target_report.ml` covers the new description (including the
  redaction), and `cli/test/test_target_status.sh` adds two end-to-end cases —
  a target pointing at `k3d-sol-local`, and a malformed
  `sol/environments.yml`.
- Negative (mutation) runs: restoring `Error _ -> Not_configured` fails the
  reserved-local assertions ("expected to find 'reserved execution mode'");
  collapsing the load error back to `[]`/"no targets found" fails the workspace
  assertions. Both mutations were reverted.

Verified with the real binary against a scratch workspace:

```text
$ sol target show --target qual/aws/reserved
kubernetes     misconfigured: this target resolves to <context>, Sol's own cluster, which is a reserved execution mode rather than a target: use `sol local <command>` for it, and point this target at a cluster you own

$ sol target show --target qual/aws/blank
kubernetes     not configured — this target names no kube_context, ... (unchanged)

$ sol target show --target qual/aws/blank   # with a malformed environments.yml
the workspace could not be read, so its targets are unknown: ...:2: invalid YAML: did not find expected node content
```

The two `Test_scaffold` inline cases fail in this fresh worktree exactly as they
do on a pristine `origin/main` worktree (`dune build` of a scaffolded workspace),
so they are environmental, not caused here.

No demo/example change: CLI target diagnostics, no app-author surface. No
language-parity impact (DEC-022).

