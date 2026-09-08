---
id: REFAC-002
type: refactor
severity: medium
source: codebase simplification review 2026-06-13
branch: REFAC-002/consolidate-run-cmd
worktree: ../sun-REFAC-002-consolidate-run-cmd
---

Consolidate the `run_cmd` shell-exec helper defined independently in five files into a shared `Sun_cli_shell` module

**Depends on:** None.

**Description:**

`run_cmd ?(echo = true) cmd` — which prints `  $ <cmd>` and calls `Sys.command` — is copy-pasted into every CLI command file:

- `cli/sun/bin/cmd_cloud.ml:9`
- `cli/sun/bin/cmd_up.ml:6` (also defines `run_cmd_to_string` at line 252)
- `cli/sun/bin/cmd_dev.ml:6` (a second shadowing definition appears at line 501)
- `cli/sun/bin/cmd_rollback.ml:8` (echo-flag missing — always prints)
- `tools/sundev/bin/cmd_pipeline.ml:15` (also defines `run_cmd_lines` at line 31)

Minor behavioural differences have already crept in (rollback's version lacks the optional `echo` flag). Any change to output formatting must be applied to all five files.

**Remediation:**

1. Add `cli/sun/lib/sun_cli_shell.ml` with:
   ```ocaml
   val run_cmd      : ?echo:bool -> string -> int
   val run_cmd_ok   : ?echo:bool -> string -> unit   (* exit non-zero → failwith *)
   val run_cmd_lines : ?echo:bool -> string -> string list
   val run_cmd_to_string : string -> string
   ```
   Consolidate the three variants (`run_cmd`, `run_cmd_lines`, `run_cmd_to_string`) from their current homes into this single module. Match the most complete behaviour (with `?(echo = true)`).
2. Expose `Sun_cli_shell` through the existing `sun_cli` library in `cli/sun/lib/dune`.
3. Replace the local definitions in all five `cmd_*.ml` and `cmd_pipeline.ml` files with calls to `Sun_cli_shell`.
4. For `cmd_pipeline.ml` (in `tools/sundev/`): either take a library dependency on `sun_cli` if the dependency graph allows, or copy the module into `tools/sundev/lib/` as a one-time promotion (note which was chosen in the commit message).

**Acceptance criteria:**

- `grep -rn "let run_cmd" cli/ tools/sundev/` returns zero results.
- `dune build` and `dune test` pass.
- `cmd_rollback.ml` now respects the `?echo` flag consistently with the other commands.

## Review — automated checks passed
REFAC-002 consolidation is complete: build clean, no duplicate run_cmd definitions, all five callers migrated to canonical modules, Sun_cli_shell registered in dune, no ticket files modified in the worktree.
