---
id: INFRA-110
type: infra
severity: low
source: implementing INFRA-109, 2026-10-04
title: The fast checks assume a built soldev and fail on a fresh worktree
---

**Depends on:** None.

## Premise verified

`internal/ci/run_fast_checks.sh` runs `dune build` and then requires
`_build/default/internal/tooling/soldev/bin/main.exe`, treating its absence as a failure
(`soldev is not built, so pipeline validate did not run`). `dune build` does not produce that
executable, so a fresh worktree — a new clone, or `git worktree add`, which is the documented way to
start a ticket — fails `fast checks: context-bound guards FAILED` on a tree that is perfectly valid.
Hit while implementing INFRA-109: the checks could not grade the very tree they were asked to grade.

## Remediation

Build what the checks use, or name the precondition and the command that satisfies it. The checks
should be able to grade a fresh worktree of a committed tip — which is also what INFRA-109 asks of
them, so the two belong together.

## Acceptance criteria

- `run_fast_checks.sh` in a fresh worktree of a clean commit passes, or performs the missing build
  step itself rather than reporting the tree as failed.
- No check depends on an artifact the default build does not produce.
- Example impact: none; developer tooling. Language-parity impact: none.
