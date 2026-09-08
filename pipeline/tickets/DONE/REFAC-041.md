---
id: REFAC-041
type: refactor
severity: high
source: codebase simplification review 2026-06-16
branch: REFAC-041/extract-consumer-group-guard
worktree: ../sun-REFAC-041-extract-consumer-group-guard
---

Extract duplicated consumer-group guard into `Sun_cli_deployment_state`

**Depends on:** None.

**Description:**

Lines 92–106 of `cli/sun/bin/cmd_up.ml` and lines 111–125 of `cli/sun/bin/cmd_deploy.ml` are identical in logic and near-identical in text: load previous groups, diff against the plan's next groups, print the same multi-line warning, and exit if any groups were removed and `--confirm-group-change` was not passed. The `confirm_group_change_flag` Cmdliner term is also copy-pasted word-for-word (`cmd_up.ml:244–247`, `cmd_deploy.ml:254–257`).

Any change to the warning text, the check semantics, or the flag name must be applied to two places in sync.

**Remediation:**

1. Extract a function `check_consumer_group_change ~workspace ~plan ~confirm_group_change` into `cli/sun/lib/sun_cli_deployment_state.ml` (it already owns `load_deployed_groups` and `removed_consumer_groups`). Add the signature to `.mli`.
2. Replace both inline blocks in `cmd_up.ml` and `cmd_deploy.ml` with a single call to this function.
3. Move the shared `confirm_group_change_flag` Cmdliner term into `cli/sun/lib/sun_cli_deploy_args.ml` (new small module) and reference it from both commands.

**Acceptance criteria:**

- `grep -n "confirm_group_change" cli/sun/bin/cmd_up.ml cli/sun/bin/cmd_deploy.ml` shows only the import/call, not the flag definition.
- `dune build` passes.
- `dune test cli/sun/` passes.

## Review — automated checks passed
REFAC-041 correctly extracts the consumer-group guard and shared flag; build and tests pass with no violations.

## Review — automated checks passed
REFAC-041 correctly extracts the consumer-group guard and shared flag; build and tests pass with no violations.
