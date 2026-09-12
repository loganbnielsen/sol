---
id: REFAC-085
type: refactor
severity: low
source: devtools value review 2026-09-11 — output that has never changed a decision
---

**Depends on:** None.

**Related:** REFAC-082, BUG-023.

Print the performance table only when a suite has actually regressed, instead of after every commit.

## Problem

`devtools/hooks/post-commit` runs `perf.sh status` unconditionally, so every commit ends with this:

```
  Suite            Baseline    Latest      Drift     Thresh   Runs
  unit             3.045s      2.614s      -14%     1.5× 670
  kafka            1.100s      1.093s      -1%      1.4× 536
  observability    —         —         —        1.4× 0
  storage          —         —         —        1.4× 0
  e2e              1.213s      1.243s      +2%      1.5× 493
```

It is informational only — the gate lives in `run_tests.sh` via pre-commit — and nothing on that table has ever changed a decision. The drifts observed across this project's recent history are single-digit percentages against thresholds of 1.4–1.5×, i.e. an order of magnitude of headroom. It also appears in `pipeline submit` output, where it is noise on a command whose actual result is a PR URL.

**The same file already shows the better pattern.** The orphaned-worktree check directly below it prints nothing when there is nothing to do, and a specific, actionable list when there is. That is the test to apply: *output belongs at the moment it changes what someone would do.*

## Scope

**1. A regressions-only mode in `perf.sh`.** `perf.sh status --regressions-only` prints the table when at least one suite has crossed its threshold, and nothing otherwise. The threshold logic already exists (`is_regression`); this is a filter over it, not new logic.

**2. `post-commit` uses it** — and drops its unconditional `echo ""`, so a clean commit prints nothing extra.

**3. Leave the parts with teeth alone.** `perf.sh status` as a human command is unchanged and stays the way to inspect on demand; the baseline file and `set-baseline`/`history` stay; and the pre-commit gate that actually fails a breached suite stays exactly as is. This ticket is about unconditional *reporting*, not about measuring less.

## Acceptance criteria

- A commit with no regression prints no table.
- A commit that does regress prints it — verified by forcing a breach, not by inspection.
- `perf.sh status` (no flag) behaves exactly as it does today.
- A suite that breaches its threshold still fails in pre-commit, unchanged.
- The hook's comment says why it is conditional, so a future reader does not "fix" it back to unconditional.

## Notes

Filed from a review of which parts of `devtools` earn their keep rather than from a failure. Two other findings from that review are handled elsewhere: the rename detection in the worktree guard (BUG-023) and the check that guards a duplicated source of truth (`check_platform_component_drift.sh`), which is the pattern worth copying.
