---
id: REFAC-040
type: refactor
severity: high
source: codebase simplification review 2026-06-16
branch: REFAC-040/consolidate-git-sha-workspace-name
worktree: ../sun-REFAC-040-consolidate-git-sha-workspace-name
---

Consolidate duplicated `git_sha` and `workspace_name` helpers into `Sun_cli_shell`

**Depends on:** None.

**Description:**

Three `cmd_*.ml` files each define their own copy of two identical helpers:

- `git_sha ()` — defined at `cmd_up.ml:15–17` (delegates to `Sun_cli_shell.run_cmd_to_string`), `cmd_deploy.ml:10–17` (tempfile + `Sys.command`), and `cmd_cloud_deploy.ml:7–14` (same tempfile approach as cmd_deploy). The implementations differ subtly, meaning the three commands can produce different results for edge cases.
- `workspace_name ()` — defined identically at `cmd_up.ml:13`, `cmd_deploy.ml:8`, and inlined at `cmd_cloud_deploy.ml:108` as `Filename.basename (Sys.getcwd ())`.

Any bug fix or behavioural change (e.g. handling detached HEAD, trimming trailing newlines) must be applied in three places.

**Remediation:**

1. Add `val git_sha : unit -> string` and `val workspace_name : unit -> string` to `cli/sun/lib/sun_cli_shell.ml` and `sun_cli_shell.mli`, using the `run_cmd_to_string` approach already present in `cmd_up`.
2. Delete the three local definitions in `cmd_up.ml`, `cmd_deploy.ml`, and `cmd_cloud_deploy.ml`.
3. Replace each call site with `Sun_cli_shell.git_sha ()` / `Sun_cli_shell.workspace_name ()`.
4. `dune build` and `grep -rn "let git_sha\|let workspace_name" cli/sun/bin/` returns zero hits.

**Acceptance criteria:**

- `grep -rn "let git_sha\|let workspace_name" cli/sun/bin/` returns zero hits.
- `dune build` passes.
- `sun up`, `sun deploy`, and `sun cloud deploy` all produce the same git SHA on a clean HEAD.

## Review — automated checks passed
git_sha and workspace_name consolidated into Sun_cli_shell; all call sites updated, build passes, and zero local definitions remain in cli/sun/bin/
