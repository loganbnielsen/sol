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

## Completion notes

Fixed 2026-10-02, `CODE_LAYER-030/sol-process-shell-family`. Premise verified
before pickup (`! rg -q 'open_process_in|Sys.command' …` — held; the family was
still there).

- `sol_process` lost the `open_process_in`/`Sys.command` family. The replacements
  are built on `run_argv [ "sh"; "-c"; cmd ]`:
  - `lines_shell_checked` / `output_shell_checked : (…, result) result` — the
    checked variants, which return the failing `result` (status, stdout, stderr)
    instead of `[]`/`""`;
  - `failure_message : result -> string` names the exit code and stderr;
  - `run_shell_rc` / `run_shell_ok` keep their signatures and their live,
    inherited output via the new `run_argv ?stream` (the child gets the parent's
    stdout/stderr, nothing is captured), so `git push` and `run_tests.sh` still
    print as they run.
- `soldev_shell.run_cmd_lines` is the checked variant now.
- `soldev_merge`'s git reads are typed: `current_branch` returns a result (a git
  failure is no longer "not on a ticket branch (currently on )"),
  `worktree_snapshot` carries `Worktree_clean | Worktree_dirty |
  Worktree_unreadable of reason` and `ws_unpushed : bool option` (`None` when git
  cannot say), and `worktree_snapshots` returns a result, so
  `worktree_annotation_for_ticket` says `(worktree state unreadable: …)` rather
  than reporting no worktree / clean. `check-reverts` fails with the read error
  instead of flagging from a `git log` that never ran. The dead
  `git_branch_exists` is gone.
- Tests: `internal/tooling/sol_process/test/test_sol_process.ml` (checked
  variants report a failing command as an error carrying its exit code and
  stderr; streaming returns the status and captures nothing) and
  `internal/tooling/soldev/test/test_merge.ml` (a fake `git` that exits 128
  produces an explicit "worktree state unreadable" annotation; a failing `git
  status` is `Worktree_unreadable`, not clean; an unresolvable base ref is
  `None`, not "unpushed").
- Negative (mutation) runs, all reverted: an always-`Ok` `lines_shell_checked` /
  `output_shell_checked` fails the two sol_process tests; `Error → Worktree_clean`
  and `Error → Ok []` fail the two soldev_merge tests.

`rg -n 'open_process_in|Sys.command' internal/tooling/sol_process/lib/sol_process.ml`
returns nothing. `dune runtest internal/tooling/sol_process/test
internal/tooling/soldev/test` passes (26 + 60 + 29 tests), and `pipeline ls` /
`pipeline check-reverts` behave (annotations still reported for the real
worktrees).

No demo/example change: internal maintainer tooling, no application-facing
behavior. No language-parity impact (DEC-022).

