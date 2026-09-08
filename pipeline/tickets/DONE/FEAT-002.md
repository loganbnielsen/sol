---
id: FEAT-002
type: feature
severity: high
source: internal
branch: FEAT-002/perf-baseline-merge
worktree: ../sun-FEAT-002-perf-baseline-merge
---

`sun pipeline merge` fails on `hygiene/test/perf_baseline.json` conflicts; baseline strategy not enforced.

**Problem:** When merging ticket branches that updated `hygiene/test/perf_baseline.json`, `git merge` conflicts on that file and aborts. Two root causes:

1. `.gitattributes` sets `hygiene/test/perf_baseline.json merge=ours` but the file is not committed, so git ignores the attribute during merge.
2. Even with the attribute committed, `sun pipeline merge` should explicitly handle the post-merge baseline verification step rather than relying silently on a git attribute.

**Remediation:**

1. **Commit `.gitattributes`** — ensure `hygiene/test/perf_baseline.json merge=ours` is tracked. This makes git automatically keep main's baseline during any merge without a conflict.

2. **Add post-merge test run to `sun pipeline merge`** — after a successful merge (including auto-resolved baseline conflicts), run the test suite. If a perf regression is detected (new run exceeds baseline by more than the allowed drift), move the ticket to `hygiene/tickets/BLOCKED_BY_PERFORMANCE/` instead of `DONE/` and print the regression details.

3. **Baseline bump logic** — if the merge passes testing cleanly, update `hygiene/test/perf_baseline.json` with the new run's times and amend it into the merge commit (or add a follow-up commit). This keeps the baseline current as new commands are added.

**Acceptance criteria:**
- `sun pipeline merge` on a branch that modifies `perf_baseline.json` completes without a conflict.
- A branch that introduces a genuine perf regression lands in `BLOCKED_BY_PERFORMANCE/` with a note showing which suite regressed and by how much.
- `hygiene/test/perf_baseline.json` on main stays current after each merge.

**Current state:** EXP-005, EXP-007, EXP-008 are stuck in `READY_TO_MERGE` with aborted merges due to this conflict. Once this fix lands, re-run `sun pipeline merge` to clear them.

## Review — returned for revision
- `.gitattributes` — Remediation item 1 requires committing .gitattributes with 'hygiene/test/perf_baseline.json merge=ours'. The branch diverged before this was added to main — fix by rebasing onto main so the attribute is included.

## Review — automated checks passed
All three remediation items are present and correct: .gitattributes with merge=ours is committed, post-merge perf test runs with correct exit-code routing, and baseline update commit is issued on clean pass.
