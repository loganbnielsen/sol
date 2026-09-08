---
id: REFAC-075
type: bug
severity: high
source: incident during REFAC-072/074's autonomous merges, 2026-09-08
---

**Depends on:** None.

`soldev pipeline merge`'s post-merge steps run against a stale pre-merge binary, causing false-positive reverts and ticket-state corruption; while fixing it, collapse the redundant bookkeeping commits it also generates.

## Problem

`soldev pipeline merge` squash-merges a PR, then — using the *currently-executing* `soldev` process, compiled before that merge landed — runs the post-merge test suite, updates the perf baseline, and moves the ticket file to `DONE`. When a merge changes a path `soldev` itself depends on (or that its test/baseline invocation shells out to), the stale binary's hardcoded pre-merge path no longer exists post-merge, the invocation fails, and `soldev`'s built-in safety net (correctly, given what it can see) treats this as a real test/perf regression and auto-reverts the merge plus moves the ticket to `BLOCKED_BY_PERFORMANCE`.

Hit this twice in one session (2026-09-08):
- **REFAC-072** (`project/`→`pipeline/`): left a split ticket-state mess across both the old and new paths that needed manual git-level reconciliation.
- **REFAC-074** (`platform/`→`cli/platform/`): triggered a full automatic revert of a 116-file merge that had already passed real GitHub CI clean — caught before the revert reached `origin/main`, but only because it was checked by hand.

This is very likely not new: git history shows **96** historical `pipeline: test failure blocked <TICKET>` / `pipeline: perf regression blocked <TICKET>` events, against only 8 `Reapply` commits — meaning most blocked tickets were apparently re-fixed from scratch rather than confirmed-and-reapplied, which is consistent with at least some fraction of those 96 being this same false-positive class rather than real regressions, silently costing rework.

Separately, but touching the same code: **45% of this repo's 2334 commits (1046) are `pipeline:` bookkeeping** — a single ticket's lifecycle currently produces up to 7 commits (`IN_PROGRESS`, `submit for review`, `move to REVIEW`, `review passed`, `move to READY_TO_MERGE`, `move to DONE`, `update perf baseline`) where several are the same logical transition split for no reason. Worth collapsing while this code is already being touched for the correctness fix, not as a separate pass.

## Remediation

**Part A — the correctness fix (required):**
- `soldev pipeline merge`'s post-merge stage (test run, perf-baseline update, ticket move to `DONE`) must run against a binary built *after* the merge commit lands, never the already-loaded pre-merge process. Concrete approaches, pick whichever fits `soldev`'s actual architecture best:
  - Split `soldev pipeline merge` into two explicit steps — `merge` (squash-merge + push only) and a `finish`/`finalize` step that runs `dune build` and then re-execs a freshly-built `soldev` binary for the test/baseline/DONE-move — with `merge` always invoking `finish` as a genuinely separate subprocess launched *after* its own rebuild, not inline in the same process.
  - Or: have the post-merge stage always shell out via `dune exec` (which rebuilds on demand) rather than relying on `self`/the resident binary.
- Add a regression test that reproduces the failure mode directly: simulate a merge that renames a path the merge tool's own test/baseline invocation depends on, confirm the old code would false-revert, confirm the fix doesn't.
- Update the `work`/`review-worktree` skill docs (and any other doc describing the merge flow) to match the corrected mechanics.

**Part B — collapse redundant bookkeeping commits (opportunistic, same PR):**
- Combine `submit for review` + `move to REVIEW` into one commit (same transition).
- Combine `review passed` + `move to READY_TO_MERGE` into one commit (same transition).
- Combine `move to DONE` + `update perf baseline` into one commit (both happen in the same merge-finish step).
- Target: a full ticket lifecycle goes from ~7 bookkeeping commits down to ~3-4, with no loss of the underlying information (git blame/history still shows exactly what happened, just not split across artificially separate commits).

## Acceptance criteria

- A worktree merge that renames a path `soldev`'s own merge-finish logic depends on completes successfully without a false-positive revert (the exact scenario that hit REFAC-072/074).
- New regression test(s) covering this in `devtools/soldev/test/`.
- A full ticket lifecycle (create → work → submit → review → merge) produces the reduced commit count end-to-end, exercised against a real scratch ticket.
- Full local test suite passes.

## Explicitly out of scope

Squashing/rewriting this repo's existing git history. That's a separate, deliberate follow-up once this fix has landed and stopped generating the same noise — no point squashing twice.
