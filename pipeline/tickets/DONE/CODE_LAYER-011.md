---
id: CODE_LAYER-011
type: bug
severity: low
source: perf-gate sign-off pattern, 2026-09-06 (CODE_LAYER-005/006/007/009)
branch: code_layer-011/perf-gate-false-positive
worktree: ../sun-code_layer-011-perf-gate-false-positive
pr: https://github.com/loganbnielsen/sun/pull/130
---

**Depends on:** None.

## Problem

`sundev pipeline merge`'s post-merge perf gate flagged an e2e-suite
timing regression four separate times in one session
(CODE_LAYER-009, CODE_LAYER-005, CODE_LAYER-006, CODE_LAYER-007), each
time in the 1.6-1.7x-over-1.5x-threshold range against a ~1.19s
baseline. Every single time, an immediate `bash
platform/local/scripts/run_tests.sh` re-run with no other change came
back at or within noise of the baseline (1.188-1.201s). None of the four
underlying diffs touched anything on the e2e path (Terraform/Helm-values
plumbing, an Alloy config renderer, a dead-code removal, dashboard JSON
loading) that would plausibly cause a real 60%+ slowdown.

Also, each time the flag fired, the automatic revert-on-regression step
itself failed ("Your local changes to the following files would be
overwritten by merge" / `tools/perf/perf_baseline.json`), leaving the
already-merged code in place but the ticket stuck in
`BLOCKED_BY_PERFORMANCE` requiring a manual sign-off + `DONE` move each
time.

## Goal

The perf gate stops crying wolf on ordinary merges, and if it ever does
fire for real, the automatic revert actually completes instead of
requiring the same manual recovery dance every time.

## Suspected cause (not confirmed)

Machine contention at merge time — this session ran several background
`Agent`/subagent processes doing their own `dune build`/`dune test`
cycles concurrently with the merge step's perf run, which would
plausibly produce exactly this kind of transient, non-reproducible e2e
timing spike. Not confirmed; could also be something else (e.g. a
resource genuinely contended by the e2e suite itself, like a port or a
shared Kafka topic).

## Remediation (not scoped in detail — needs investigation first)

- Confirm or rule out the contention theory: check whether the perf gate
  runs `dune test` with any isolation from concurrent processes, or
  whether it could take a second measurement before flagging (e.g.
  re-run the failing suite once in-place before declaring a regression,
  the same recovery step a human currently does by hand).
- Fix the automatic-revert failure on `tools/perf/perf_baseline.json` so
  a genuine regression doesn't leave the ticket in a broken
  half-merged-half-blocked state requiring manual `git status`
  archaeology to recover from.
- Consider whether the e2e suite's 1.5x threshold is simply too tight
  for its own baseline's variance, independent of any contention theory.

## Acceptance criteria

- A documented root cause (or a documented "investigated, inconclusive,
  here's the mitigation anyway") for the repeated false positive.
- The automatic revert path either works reliably, or is replaced with a
  clean single-step failure mode that doesn't require manual recovery.

## Review — automated checks passed
Build clean; diff scoped to run_tests.sh, sundev_merge.ml, WORK_SUMMARY.md, perf_baseline.json history; two independent fresh adversarial review rounds (one found and confirmed-fixed a real errexit-abort bug, verified via a forced-failure repro; second found nothing actionable); full unit+kafka+e2e suite passes with no regression; CI green.
