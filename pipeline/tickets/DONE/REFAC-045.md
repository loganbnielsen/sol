---
id: REFAC-045
type: refactor
severity: high
source: codebase simplification review 2026-06-16
branch: REFAC-045/extract-temp-file-helpers
worktree: ../sun-REFAC-045-extract-temp-file-helpers
---

Replace scattered temp-file + `Sys.command` pattern with `Sun_process` helpers

**Depends on:** None.

**Description:**

Four CLI modules independently implement the same write-to-temp-file → run-command → delete-temp-file lifecycle, accumulating over 80 lines of duplicated boilerplate:

- `sun_cli_secret.ml:79–95` — defines `write_tmp` and `apply_manifest` over `Sys.command`; also re-defines `run_command` (lines 71–73) as a one-liner that bypasses `Sun_process` entirely.
- `sun_cli_manifest.ml:63–92` — defines its own `write_tmp` plus two `apply` helpers.
- `sun_cli_port_forward.ml:15–78` — repeats the open/read/delete pattern at least five times for ps/ss/pid files.
- `sun_cli_deployment_state.ml:6–16, 33` — same pattern again.

Each site independently manages temp-file cleanup, none use `Fun.protect` or similar, so a failed command leaks the file. `sun_cli_secret.ml`'s `run_command` also silently drops stderr.

**Remediation:**

1. Add two helpers to `tools/sun_process/lib/sun_process.ml`:
   - `with_tmp_file : string -> string -> (string -> 'a) -> 'a` — writes content to a temp path, calls the callback, always deletes the file.
   - `capture_cmd : string -> (int * string)` — runs a shell command and returns (exit_code, stdout).
2. Expose both in `sun_process.mli`.
3. Replace all four sites with calls to these helpers.
4. Delete `sun_cli_secret.run_command` and use `Sun_process.run_rc` instead.

**Acceptance criteria:**

- `grep -rn "Sys.command\|write_tmp" cli/sun/lib/` returns zero hits.
- `dune build` and `dune test cli/sun/` pass.

## Review — automated checks passed
with_tmp_file and capture_cmd added to sun_process; all four call sites replaced; run_command and write_tmp deleted; build and acceptance grep clean
