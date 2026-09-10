---
id: REFAC-078
type: refactor
severity: medium
source: user session discussion 2026-09-09/10 while merging INFRA-006 follow-up PRs
---

**Depends on:** None. **Sequencing note:** implement after the BUG-017 / FEAT-040 / BUG-019 PRs merge. Those branches still carry old-style `perf_baseline.json` history appends; letting them land first avoids entangling this refactor's own baseline file with the legacy behavior it removes.

Decouple `devtools/perf/perf_baseline.json` from code PRs, and remove the local perf-ratio merge gate / auto-revert behavior. Perf history and baselines become main-only informational diagnostics; functional CI and test timeouts remain the merge gate.

## Problem

### Perf baseline noise and conflicts

Every code commit runs the pre-commit hook, which runs the test suites, appends a perf-history entry to `devtools/perf/perf_baseline.json`, and stages that file into the same code commit. This causes three problems:

1. **Concurrent PRs conflict on the same file.** Every branch created from the same `main` appends entries to the same `unit.history` / `kafka.history` arrays, so two open PRs cannot both squash-merge cleanly without rebasing/conflict resolution.
2. **The recorded commit SHA is wrong.** The pre-commit hook runs before the new commit exists, so `run_tests.sh` records the current `HEAD` — normally the base `main` SHA — rather than the PR commit whose performance is being measured. Multiple unrelated PRs can therefore append identical-looking history entries for the same base SHA.
3. **Every PR diff is noisy.** A small code change carries a multi-hundred-line JSON diff purely from perf-run history, making review harder and masking the actual change.

`.gitattributes` currently marks the file `merge=ours`, which helps local `git merge` but is not a reliable solution for GitHub squash merges. GitHub does not auto-resolve conflicts, does not skip CI for baseline-only rebases, and does not run custom merge drivers.

### Local perf gate is out of step with the GitHub-PR flow

`soldev pipeline merge-finish` currently runs a local post-merge test/perf pass and **auto-reverts** a PR when local timings exceed a perf ratio. That design is fragile:

- The GitHub PR (CI + review + squash merge) is already the source of truth.
- The perf gate only runs when someone uses `soldev pipeline merge` on the same machine where the baseline was recorded.
- Merging through the GitHub UI or `gh pr merge` skips it entirely.
- GitHub-hosted CI timings differ from local timings, and local timings differ across machines/loads, so ratio comparisons are not a reliable cross-environment signal.
- Auto-reverting a remote-merged PR based on a local timing blip is a poor undo mechanism and can be bypassed silently.

## Goal

- `perf_baseline.json` never appears in a code PR unless that PR intentionally changes perf tooling semantics.
- History entries are only appended when a real baseline/history update is being recorded against a real merged commit on `main`.
- Multiple open PRs do not conflict on `perf_baseline.json`.
- Pre-commit still runs tests and enforces test timeouts; it does not persist perf history into the commit.
- Local perf ratios do **not** block or revert merges. Perf results are informational diagnostics only.
- Hard timeouts (in CI and in `run_tests.sh` suite timeouts) remain failures — they catch hangs and pathological slowdowns without relying on noisy ratio thresholds.

## Remediation

- In `cli/platform/local/scripts/run_tests.sh`, only append perf history when `--update-baseline` is set. Ordinary test runs (including pre-commit) should leave `perf_baseline.json` untouched. Keep suite timeouts as hard failures.
- In `devtools/hooks/pre-commit`, stop `git add devtools/perf/perf_baseline.json` at the end of the hook. The hook may still use the committed baseline for informational comparison, but must not write or stage it.
- In `devtools/soldev/lib/soldev_merge.ml`, remove the perf-regression auto-revert path from `run_merge_finish` and remove the `--accept-performance-regression` merge flag (or make it a no-op if callers already rely on the flag existing). A post-merge `perf_rc = 2` must not revert the merge.
- Keep `soldev pipeline merge-finish` (or an equivalent maintenance command) as the single writer of persisted perf history/baseline entries on `main`, recording the merged squash commit's SHA.
- Update `devtools/hooks/post-commit` / `perf.sh` status output as needed so a clean commit does not leave the working tree dirty.
- Add/adjust tests or a manual verification path proving:
  - (a) a normal code commit contains no `perf_baseline.json` change,
  - (b) a perf-ratio regression on a post-merge run does **not** revert the merge,
  - (c) `merge-finish` records the merged commit SHA when it does write history,
  - (d) suite timeouts still fail loudly.

## Acceptance criteria

- A fresh code commit staged through the pre-commit hook produces a diff with **no** `devtools/perf/perf_baseline.json` modification.
- Running `cli/platform/local/scripts/run_tests.sh` without `--update-baseline` does not modify `perf_baseline.json`.
- Simulating a perf-ratio regression in a post-merge run leaves the merge in place (no auto-revert) and does not require `--accept-performance-regression`.
- Running `soldev pipeline merge` for a PR appends exactly one history entry per suite to `perf_baseline.json`, recording the merged squash commit's SHA.
- Two open PRs based on the same `main` no longer conflict solely because of `perf_baseline.json`.
- `perf.sh status` still works for suites with no recorded history (BUG-019's fix stays intact).
- Suite timeouts still cause a non-zero exit and block the relevant test/CI step.
