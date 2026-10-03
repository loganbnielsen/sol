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
