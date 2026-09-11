---
id: REFAC-079
type: refactor
severity: low
source: user session discussion 2026-09-09/10 about whether soldev is still the right tool shape
---

**Depends on:** REFAC-078 (its perf-gate removal changes soldev's merge/merge-finish behavior; audit after that lands so this ticket sees the post-REFAC-078 shape).

Audit `soldev`'s remaining local-only behaviors and prune anything that duplicates or overrides GitHub as the source of truth.

## Problem

`soldev pipeline` is most useful when it is a thin orchestration layer over GitHub: listing tickets, preflight checks, opening PRs, posting review verdicts, and driving `gh pr merge`. But it still contains local-only steps that can act as a second authority:

- `merge-finish` runs the post-merge test suite and records perf history **locally**, after the GitHub merge already happened. If the merge is done through the GitHub UI or `gh pr merge`, this step never runs.
- Pre-commit tests run locally and can be skipped with `SOL_SKIP_HOOKS=1`; GitHub CI is the actual required PR gate.
- Ticket-directory bookkeeping commits are pushed directly to `main`, bypassing the PR process for those file moves.
- Post-commit orphaned-worktree checks, local branch/worktree cleanup, and other local conveniences may be useful, but their value vs. maintenance cost has not been reassessed since REFAC-077/078.

None of these are necessarily wrong, but they should each have a stated reason for existing locally rather than being GitHub-native or removed.

## Goal

After this ticket, every `soldev` command and hook has a clear role:

- **Orchestration** — talks to GitHub and makes the PR flow deterministic.
- **Informational** — local diagnostics that never act as a merge authority.
- **Removed** — anything that duplicates GitHub state, can be silently skipped, or acts as a second source of truth without adding real protection.

## Remediation

- Inventory `devtools/soldev/bin/cmd_pipeline.ml`, `devtools/soldev/lib/soldev_merge.ml`, `devtools/hooks/*`, and `.claude/skills/work/SKILL.md` + `review-worktree/SKILL.md`.
- For each command/hook, classify as orchestration / informational / remove-or-replace, with a one-line justification.
- Pay special attention to:
  - `merge-finish` — decide whether it should remain a local maintenance step (record informational perf history), become a separate maintenance command, or be removed now that perf ratios no longer gate merges.
  - Pre-commit vs. GitHub CI — decide whether local tests are a convenience gate or a redundant authority; make that explicit in docs/skills.
  - Direct-to-`main` ticket-file commits (BACKLOG → READY promotions) — document why these bypass PRs, or migrate them to PRs if practical.
  - Post-commit orphaned-worktree warnings and any other local cleanup.
- Update docs/skills to state which soldev behaviors are authoritative vs. convenience.

## Acceptance criteria

- A written inventory (in the PR description or a doc) lists every soldev command/hook and its classification.
- No soldev local-only step is treated as a required merge authority unless GitHub CI or GitHub state cannot provide the same guarantee.
- `merge-finish`'s role after REFAC-078 is explicit: either kept as an informational/maintenance command with a reason, or removed.
- Skills and CLAUDE.md match the final behavior.
