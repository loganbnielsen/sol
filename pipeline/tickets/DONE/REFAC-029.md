---
id: REFAC-029
type: refactor
severity: medium
branch: REFAC-029/extract-helm-rendering
worktree: /home/lbendtly/Code/sun-REFAC-029-extract-helm-rendering
source: codebase simplification review 2026-06-15
---

Decompose cmd_up.ml (551 lines) by extracting port-forward helpers and YAML rendering

**Depends on:** REFAC-021, REFAC-023.

**Description:**

`cli/sun/bin/cmd_up.ml` is 551 lines. After REFAC-021 (state dir) and REFAC-023 (port-forward module) land, the file will still be ~350 lines mixing two concerns:

1. **Port-forward management** (lines 41–240 before extraction) — already covered by REFAC-023.
2. **YAML/Helm values rendering** (lines 240–400 approx.) — `render_values`, `render_services`, `render_service_entry`, `values_of_workspace`. These produce the Helm `values.yaml` that `sun up` passes to `helm upgrade`.
3. **`sun up` command orchestration** (the actual entry point that ties everything together).

The YAML rendering logic is non-trivial (~150 lines) and is a natural unit to test in isolation. It is also a candidate for sharing with `sun deploy` (REFAC-020 notes that both `cmd_up.ml` and `cmd_deploy.ml` render similar manifests).

**Remediation:**

1. After REFAC-021 and REFAC-023 land, extract YAML/Helm values rendering from `cmd_up.ml` into `cli/sun/lib/sun_cli_helm.ml`:
   ```ocaml
   val render_values : workspace_spec -> string  (* returns YAML string *)
   ```
   Move `render_values`, `render_services`, `render_service_entry`, `values_of_workspace` into this module.

2. Check whether `cmd_deploy.ml` has overlapping YAML rendering; if so, unify under `Sun_cli_helm` in the same pass.

3. `cmd_up.ml` becomes the orchestrator only: read workspace, call `Sun_cli_helm.render_values`, write temp file, call helm, manage port-forwards via `Sun_cli_port_forward`. Target: ≤150 lines.

**Acceptance criteria:**

- `cmd_up.ml` is ≤150 lines after all three REFAC-021/023/029 tickets are resolved.
- `sun_cli_helm.ml` has unit tests for `render_values` (no broker or Kubernetes needed).
- `dune build` passes.
- `sun up --dry-run` output is identical before and after.

## Review — automated checks passed
cmd_up.ml reduced to 115 lines via Sun_cli_docker and Sun_cli_deploy extraction; build passes; diff scoped; Fun.protect cleanup present
