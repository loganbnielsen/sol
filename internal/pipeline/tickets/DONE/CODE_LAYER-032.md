---
id: CODE_LAYER-032
type: bug
severity: low
title: The shell-family replacement captures the output the operator reads, and drops the reason a git read failed
source: "CODE_LAYER-030 (#953, merged 2026-10-03T01:43:48Z) merge review"
---

The shell-family replacement captures the output the operator reads, and drops
the reason a git read failed

**Depends on:** None.

**Related (not a dependency):** CODE_LAYER-030 (the merged replacement),
`BUG-033` (merge-finish reports a local failure without reverting).

## Problem

CODE_LAYER-030 replaced `Sol_process`'s `open_process_in`/`Sys.command` family
with `run_argv` wrappers, which capture both streams so that status and stderr
survive. Three consequences were not carried across in `internal/tooling/soldev/`.

**1. `run_shell_rc` no longer streams.** It went from `Sys.command cmd` — which
inherits the parent's stdout and stderr — to:

```ocaml
let run_shell_rc ?(echo = true) cmd = exit_code (run_shell ~echo cmd)
```

which captures them and drops the result. `Soldev_shell.run_cmd` is
`run_shell_rc`, and the commands it runs are exactly the ones whose output the
operator reads:

- `run_submit`'s `git push -u origin <branch>` — the remote's summary, including
  GitHub's "Create a pull request…" line;
- `run_merge_finish`'s `./internal/tooling/scripts/run_tests.sh` — a multi-minute
  suite whose per-check PASS/FAIL lines are the report;
- `merge_candidates`'s `gh pr merge …`.

Each prints the `$ <command>` echo line and then nothing until it exits, so a long
push or suite run is silent.

**2. A failed `run_cmd` loses the reason.** The call sites report only the exit
code they computed, e.g. `error: git push failed for %s`, so a push rejected by
the remote or by the pre-push hook prints no explanation. This is visible in
practice: a `soldev pipeline submit` here reported `error: git push failed for
VERIF-025/report-the-cause` while a manual `git push` of the same commit
succeeded, and the captured stderr that would have said why was discarded.

**3. Two git reads in `soldev_merge.ml` still fold a failure into a definite
answer** — the class CODE_LAYER-030's remediation item 2 named ("migrate
`soldev_merge`'s git reads to the checked variant") but the merge covered only
the worktree snapshot:

- `current_branch ()` maps any `git rev-parse --abbrev-ref HEAD` failure to `""`;
  `run_submit` then refuses with "error: not on a ticket branch (currently on )"
  — a definite claim from a read that did not complete.
- `refixed_after` maps a failed `git log <range>` to `false`, so
  `run_check_reverts` counts the ticket as un-refixed and reports a verdict it
  could not establish; a failed `git log --grep` read is reported as "clean".

## Impact

Operator-visible diagnostic loss in the maintainer tooling: the commands that
print progress are silent, and the two failures that currently announce
themselves as "push failed" and "not on a ticket branch" name neither their cause
nor, in the second case, that the read failed at all.

## Remediation

1. Give `Sol_process.run_argv` an explicit `?stream` (default false): when set,
   the child inherits the parent's stdout/stderr instead of pipes, and the
   returned result carries the status with empty `stdout`/`stderr`.
   `run_shell_rc`/`run_shell_ok` use it, so they keep their signatures and their
   live output; the capturing entry points (`run_shell`,
   `output_shell_checked`, `lines_shell_checked`) are unchanged.
2. Report the reason where `run_cmd` fails: `Soldev_shell` grows a
   `run_cmd_result` returning the captured `Sol_process.result`, and the call
   sites render its exit code and stderr with a shared formatter (add
   `Sol_process.failure_message`, mirroring `Sol_cli_process.error_to_string`).
   At minimum `run_submit`'s push failure and the `merge`/`review` call sites name
   the captured stderr.
3. `current_branch` returns a `result` (or an `Unreadable` case) and `run_submit`
   refuses with the read's reason. `refixed_after` returns a result and
   `run_check_reverts` fails with "git log could not be read: <reason>" instead of
   reporting a verdict.

## Acceptance criteria

- `soldev pipeline submit` shows the push's own output and, when the push fails,
  the captured reason; `merge-finish` shows the suite's output as it runs.
- A test pins that a streamed run returns its exit status and captures nothing,
  and a test pins that a failed `run_cmd_result` carries the reason.
- A failed `git rev-parse --abbrev-ref HEAD` refuses with the reason rather than
  "currently on "; a failed `git log` in `check-reverts` is reported as
  unreadable, not as clean.
- `internal/tooling/sol_process/test/` and `internal/tooling/soldev/test/` pass.

**Demo/example coverage:** Not applicable — internal maintainer tooling, no
app-author surface.

**TypeScript-parity note (DEC-022):** No language-parity impact — `soldev` and
`sol_process` are the repository's own tooling.

## Completion notes

Fixed 2026-10-02, `CODE_LAYER-032/shell-output` (the ticket was filed as
`#968`, then implemented).

- `Sol_process.run_argv` gained `?stream`: when set, the child is spawned with the
  parent's `stdout`/`stderr` instead of pipes and the returned `result` carries
  the status with empty `stdout`/`stderr`. `run_shell` passes it through and
  `run_shell_rc` uses it, so `git push`, `run_tests.sh` and the other `run_cmd`
  call sites print as they run again. The capturing entry points are unchanged.
- `Sol_process.failure_message` renders "exited with code N" plus stderr
  (mirroring `Sol_cli_process.error_to_string`); `soldev`'s private
  `read_failure_reason` is gone in favour of it.
- `Soldev_shell.run_cmd_checked` returns the captured `result`; `merge_candidates`
  prints `merge request failed: <reason>` and `run_review`'s two `gh pr comment`
  sites name the reason instead of only the PR. `run_submit`'s push failure now
  names the exit code (its output is on the terminal, streamed).
- `current_branch` returns `result` and refuses with "the current branch could
  not be read: <reason>"; `refixed_after` propagates and `run_check_reverts`
  fails with "check-reverts: git log could not be read: <reason>" rather than
  reporting the tree clean.

Tests: `sol_process/test/test_sol_process.ml` pins that a streamed run reports its
status and captures nothing, that its output reaches the parent's stdout (the
test redirects the process's own fd 1 and looks for a unique marker), and that
`failure_message` names the code and stderr. `soldev/test/test_merge.ml` pins the
three reason-carrying paths with a failing fake `git` on `PATH`.

Negative (mutation) runs, all reverted: ignoring `?stream` fails the
output-reaches-stdout test; restoring `Error _ -> Ok ""` in `current_branch` fails
"the current branch names a failed read"; restoring the unchecked
`run_cmd_lines_checked` fails "check-reverts refuses to report a log it could not
read"; an always-`Ok` `run_cmd_checked` fails "a checked run carries the exit code
and stderr".

`dune runtest internal/tooling/sol_process/test internal/tooling/soldev/test`
passes (26 + 60 + 32 tests).

No demo/example change: internal maintainer tooling. No language-parity impact
(DEC-022).

