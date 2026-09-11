---
id: REFAC-032
type: refactor
severity: low
branch: REFAC-032/remove-cmd-ok
worktree: /home/lbendtly/Code/sun-REFAC-032-remove-cmd-ok
source: codebase simplification review 2026-06-15
---

Remove three `cmd_ok` aliases — `Sun_cli_shell.run_cmd_ok` already exists

**Depends on:** None.

**Description:**

Three bin files define a local `cmd_ok` alias with divergent implementations:

| File | Line | Implementation |
|------|------|----------------|
| `cli/sun/bin/cmd_dev.ml` | 4 | `Sun_cli_shell.run_cmd ~echo:false cmd = 0` |
| `cli/sun/bin/cmd_cloud.ml` | 7 | `Sun_cli_shell.run_cmd ~echo:false cmd = 0` |
| `cli/sun/bin/cmd_status.ml` | 3–4 | `Sys.command (Printf.sprintf "%s >/dev/null 2>&1" cmd) = 0` |

`sun_cli_shell.ml` already exports `run_cmd_ok : ?echo:bool -> string -> bool`. The `cmd_status.ml` version is notably different: it appends `>/dev/null 2>&1` to the command string via sprintf (which would double-redirect if the caller already includes those), rather than using the shell module's `~echo:false` flag.

**Remediation:**

1. Delete the `let cmd_ok` definitions from all three files.
2. Replace every `cmd_ok` call site with `Sun_cli_shell.run_cmd_ok ~echo:false`.
3. Verify `cmd_status.ml`'s callers don't already embed `>/dev/null` in their command strings (they likely don't, since they relied on the local wrapper to suppress output).

**Acceptance criteria:**

- `grep -rn "^let cmd_ok" cli/sun/bin/` returns zero hits.
- `dune build` passes.

## Review — automated checks passed
All three cmd_ok definitions removed, build passes, diff scoped correctly
