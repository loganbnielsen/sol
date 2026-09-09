---
id: REFAC-078
type: refactor
severity: medium
source: user session discussion 2026-09-09/10 while merging INFRA-006 follow-up PRs
---

**Depends on:** None. **Sequencing note:** implement after the BUG-017 / FEAT-040 / BUG-019 PRs merge. Those branches still carry old-style `perf_baseline.json` history appends; letting them land first avoids entangling this refactor's own baseline file with the legacy behavior it removes.

Make `devtools/perf/perf_baseline.json` a main-only file that code PRs never touch. History/baseline updates should be written only by the post-merge pipeline using the actual merged commit SHA.

## Problem

Every code commit runs the pre-commit hook, which runs the test suites, appends a perf-history entry to `devtools/perf/perf_baseline.json`, and stages that file into the same code commit. This causes three problems:

1. **Concurrent PRs conflict on the same file.** Every branch created from the same `main` appends entries to the same `unit.history` / `kafka.history` arrays, so two open PRs cannot both squash-merge cleanly without rebasing/conflict resolution.
2. **The recorded commit SHA is wrong.** The pre-commit hook runs before the new commit exists, so `run_tests.sh` records the current `HEAD` — normally the base `main` SHA — rather than the PR commit whose performance is being measured. Multiple unrelated PRs can therefore append identical-looking history entries for the same base SHA.
3. **Every PR diff is noisy.** A small code change carries a multi-hundred-line JSON diff purely from perf-run history, making review harder and masking the actual change.

`.gitattributes` currently marks the file `merge=ours`, which helps local `git merge` but is not a reliable solution for GitHub squash merges. GitHub does not auto-resolve conflicts, does not skip CI for baseline-only rebases, and does not run custom merge drivers.

## Goal

- `perf_baseline.json` never appears in a code PR unless that PR intentionally changes perf tooling semantics.
- History entries are only appended when a real baseline update is being recorded against a real merged commit on `main`.
- Multiple open PRs do not conflict on `perf_baseline.json`.
- Pre-commit still runs the full test/regression gate; it just does not persist perf history into the commit.

## Remediation

- In `cli/platform/local/scripts/run_tests.sh`, only append perf history when `--update-baseline` is set. Ordinary test runs (including pre-commit) should leave `perf_baseline.json` untouched.
- In `devtools/hooks/pre-commit`, stop `git add devtools/perf/perf_baseline.json` at the end of the hook. The hook may still use the committed baseline for regression checks, but must not write or stage it.
- `soldev pipeline merge-finish` already runs `run_tests.sh --update-baseline` after a merge; confirm it remains the single writer of persisted history/baseline entries and that `HEAD` at that point is the merged squash commit.
- Update `devtools/hooks/post-commit` / `perf.sh` status output as needed so a clean commit does not leave the working tree dirty.
- Add/adjust tests or a manual verification path proving: (a) a normal code commit contains no `perf_baseline.json` change, and (b) `merge-finish` records the merged commit SHA.

## Acceptance criteria

- A fresh code commit staged through the pre-commit hook produces a diff with **no** `devtools/perf/perf_baseline.json` modification.
- Running `cli/platform/local/scripts/run_tests.sh` without `--update-baseline` does not modify `perf_baseline.json`.
- Running `soldev pipeline merge` for a PR appends exactly one history entry per suite to `perf_baseline.json`, recording the merged squash commit's SHA.
- Two open PRs based on the same `main` no longer conflict solely because of `perf_baseline.json`.
- `perf.sh status` still works for suites with no recorded history (BUG-019's fix stays intact).
