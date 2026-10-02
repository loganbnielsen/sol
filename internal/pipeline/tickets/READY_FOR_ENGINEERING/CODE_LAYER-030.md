---
id: CODE_LAYER-030
type: refactor
severity: low
title: Retire the open_process_in shell family in sol_process
source: internal/pipeline/audits/2026-10-02_code_layer_audit.md
premise: "! rg -q 'open_process_in|Sys.command' internal/tooling/sol_process/lib/sol_process.ml"
---

Retire the open_process_in shell family in sol_process

**Depends on:** None.

**Related (not a dependency):** `REFAC-113` asks whether `Sol_cli_process`
should sit on `bos`. This finding is independent of that decision — the legacy
family should not exist whether or not `bos` is adopted.

## Problem

`internal/tooling/sol_process/lib/sol_process.ml` exposes two families of
runner. The argv family (`run_argv`, and `run_shell` delegating to it) returns
`{status; stdout; stderr}` and drains both pipes. Beside it sits a legacy family
that does neither:

- `lines_shell` (`sol_process.ml:158-164`) and `output_shell`
  (`sol_process.ml:166-172`) run `Unix.open_process_in (cmd ^ " 2>/dev/null")`
  and return lines or a trimmed string — no exit status, stderr discarded.
- `run_shell_rc` (`sol_process.ml:174-177`) returns `Sys.command cmd`.
- `run_shell_ok` (`sol_process.ml:179-182`) raises on a nonzero `Sys.command`.

`internal/tooling/soldev/lib/soldev_merge.ml` reads git state through them:
`current_branch` via `output_shell` (`soldev_merge.ml:11-13`),
`git_branch_exists` via `run_shell_rc` (`soldev_merge.ml:15-19`),
`shell_output_trim` (`soldev_merge.ml:908`) for `git status --porcelain` and
`git rev-list --count`, and `worktree_snapshots` via
`Soldev_shell.run_cmd_lines` → `lines_shell` (`soldev_merge.ml:952-955`). A
failed `git worktree list` becomes `[]` and a failed `git status` becomes `""`
→ `dirty = false`, so a worktree annotation reports "no worktree" or "clean"
when git actually errored. This is the same error/empty conflation that
`CODE_LAYER-024` fixed for `open_prs` in this file, still present on the other
call sites.

## Remediation

1. Delete the `open_process_in`/`Sys.command` family. Reimplement
   `output_shell`/`lines_shell`/`run_shell_rc`/`run_shell_ok` as thin wrappers
   over `run_argv [ "sh"; "-c"; cmd ]` that preserve their current signatures
   where a caller cannot yet take a result, and add a checked variant returning
   `(string, result) result`.
2. Migrate `soldev_merge`'s git reads to the checked variant so a nonzero git
   exit is a distinct "unreadable" outcome rather than an empty value: the
   worktree snapshot should carry `unknown`/`unreadable` and annotate it as
   such, not as clean.
3. Update `internal/tooling/soldev/lib/soldev_shell.ml` and
   `internal/tooling/sol_process/test/test_sol_process.ml` accordingly.
4. Coordinate with the verification workstream before editing
   `internal/tooling/sol_process/test/` — its dune membership is in flux.

## Acceptance criteria

- `rg -n 'open_process_in|Sys.command' internal/tooling/sol_process/lib/sol_process.ml`
  returns nothing.
- A failing `git worktree list`/`git status` is reported as unreadable, not as
  "no worktree"/"clean": a fake git that exits nonzero produces an explicit
  unknown annotation.
- `internal/tooling/sol_process/test/` and `internal/tooling/soldev/test/`
  still pass.
- Update a runnable example/demo for application-facing behavior, or record why
  this is an internal-only refactor (maintainer tooling).
- Record the per-language capability verdict for framework/application
  contracts, or explain why language parity is unaffected.
