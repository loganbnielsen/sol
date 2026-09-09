---
id: REFAC-077
branch: REFAC-077/collapse-ticket-states
worktree: ../sol-REFAC-077-collapse-ticket-states
type: refactor
severity: high
source: git-history-noise discussion with user, 2026-09-08/09
pr: https://github.com/loganbnielsen/sol/pull/172
---

**Depends on:** None. **Sequencing note:** do this alone, not concurrently with other ticket-pipeline work — it changes the pipeline tooling every other ticket runs through. All of `IN_PROGRESS/`, `REVIEW/`, `READY_TO_MERGE/`, `BLOCKED_BY_PERFORMANCE/` are empty as of filing — no in-flight tickets need migrating, so there's no cleanup debt to carry into this change. Do it now, not later.

Collapse the ticket state machine to `READY_FOR_ENGINEERING` + `DONE`, with the `DONE` transition committed on the PR branch itself — eliminating almost all direct-to-`main` ticket-lifecycle commits.

## Decision

REFAC-075 (merged today) fixed a real correctness bug in `soldev pipeline merge` and reduced the ticket lifecycle from ~7 direct-to-`main` bookkeeping commits to ~4. Investigating further (prompted by the user noticing "just for ticket status" commits still showing up after today's git-history squash) found the deeper issue: **squashing a PR's branch commits does nothing for ticket-lifecycle commits, because they never touch a PR branch at all** — `project/tickets/`'s own rule ("only ever modified in the main checkout, never inside a worktree branch," carried forward as `pipeline/tickets/` after REFAC-072) means every `IN_PROGRESS`/`REVIEW`/`READY_TO_MERGE`/`DONE` transition is, by design, a separate direct push to `main` that bypasses branch protection (`gh`'s own "Bypassed rule violations... Changes must be made through a pull request" message, seen on every single one of these all day). No amount of PR-side squashing touches that.

**The fix:** stop treating the `DONE` transition as separate from the code change it describes. If the ticket's move from `READY_FOR_ENGINEERING` to `DONE` is committed *on the PR branch itself* (the worker's own commit, alongside the code), then `gh pr merge --squash` naturally carries it into the same single commit that lands on `main`. No separate `main`-side commit for it, ever.

Once that's true, the intermediate states (`IN_PROGRESS`, `REVIEW`, `READY_TO_MERGE`) turn out to be tracking information GitHub already has for free:
- "In progress" = an open PR/branch exists referencing this ticket ID. No local marker needed.
- "In review" / bounced = normal PR commit history (a bounce is just another commit on the same open PR — already this repo's established convention). No ticket-file move needed to represent it.
- "Ready to merge" = PR review passed + CI green, both directly queryable from GitHub. No local marker needed.

**A real bug this fixes as a side effect:** `EXP-032` found that a merge reverted after the fact leaves a stale `DONE` ticket, because the ticket-move and the code are on separate commits — reverting one doesn't revert the other. Under this design they're the *same* commit, so a revert atomically un-does both. `soldev pipeline check-reverts` (built for EXP-032) becomes a defense-in-depth safety net rather than a load-bearing fix — keep it, but it should rarely if ever fire once this lands.

**Double-pickup:** not a concern worth building a lock for — the agent/human directing the pipeline is already responsible for not dispatching the same ticket twice (this is how today's session actually worked: one ticket's worktree/PR in flight at a time, by orchestrator discipline, not by a tool-enforced lock). No `soldev`-side claim mechanism is required.

## Remediation

**`devtools/soldev/lib/` (the core logic):**
- Remove `IN_PROGRESS`, `REVIEW`, `READY_TO_MERGE`, `BLOCKED_BY_PERFORMANCE` as ticket-directory states. Only `BACKLOG`, `READY_FOR_ENGINEERING`, `DONE` remain (`BACKLOG` is unaffected by this ticket — it's a pre-work human-judgment gate, not part of the in-flight lifecycle).
- `soldev pipeline submit` (or whatever it becomes): pushes the branch, opens the PR via `gh pr create`. Does **not** touch `pipeline/tickets/` on `main` at all. The worker's own last commit on the branch already did the `READY_FOR_ENGINEERING → DONE` `git mv` as part of implementing the ticket.
- `soldev pipeline merge`: checks the PR's review-approval and CI status directly via `gh` (no dependency on any local ticket-directory state — this also subsumes the "wait for CI, then promote" logic that was previously a manual orchestrator step), then runs `gh pr merge --squash --delete-branch`. The ticket lands in `DONE` on `main` because that's part of the squashed diff, not because `soldev` moved it separately.
- `soldev pipeline check-reverts` stays as-is (defense in depth), but update its own doc comment to note it should be rare now.
- `soldev pipeline ls`/`check`: "in progress" tickets should now be represented by cross-referencing `READY_FOR_ENGINEERING` tickets against open PRs (via the `pr:` frontmatter field once set, or a live `gh pr list` query) rather than a separate directory.

**Skill docs (`.claude/skills/`):**
- `work/SKILL.md`: rewrite the dispatch logic. No more "resume `IN_PROGRESS`" branch in the old sense — resuming means finding the existing branch/PR for a ticket that already has one and continuing there. No more separate "submit for review" ticket-move step. The worker's own final commit on the branch does the `DONE` move directly, as part of implementing the ticket, before submitting.
- `review-worktree/SKILL.md`: review now operates entirely on the PR (commits, comments, CI) with no ticket-directory moves. Update accordingly.
- Any other skill referencing the old five-state model (audits, dogfood) — check and update.

**`.claude/CLAUDE.md`:** rewrite the "Ticket system" section's directory list and state-machine description to match. Note explicitly that `pipeline/tickets/` is still only ever modified from the main checkout for the two states that DO live there (`BACKLOG`/`READY_FOR_ENGINEERING` moves, e.g. audit-materialized findings) — the `DONE` transition is the one specific exception, since it happens on the branch by design.

**Out of scope for this ticket:** creating `.codex`/`AGENTS.md` to give OpenAI's Codex CLI the same conventions — no such config exists in this repo yet (checked: no `.codex/`, no `AGENTS.md`). That's new work, not a sync, and belongs in its own ticket if wanted later.

## Acceptance criteria

- A full ticket lifecycle (`READY_FOR_ENGINEERING` → worked → PR opened → reviewed (including at least one bounce-and-refix round) → merged) produces **zero** direct-to-`main` commits for ticket-state bookkeeping — the only thing landing on `main` is the one squashed PR commit, which itself contains the ticket's `DONE` move.
- A merge that gets reverted (simulate this, matching REFAC-074's real incident shape) leaves the ticket back in `READY_FOR_ENGINEERING` automatically, not stuck in a falsely-`DONE` or orphaned state.
- `IN_PROGRESS/`, `REVIEW/`, `READY_TO_MERGE/`, `BLOCKED_BY_PERFORMANCE/` directories removed (with `.gitkeep` files), and no remaining doc/skill/tool reference to them.
- Full local test suite passes; `devtools/soldev/test/` has coverage for the branch-side `DONE` move expectation and the review/merge status-checking logic.
- Exercised end-to-end against a real scratch ticket (create, work, PR, review, merge) before considering this done — this ticket is exactly the kind of thing that needs to be proven working, not just unit-tested, given how much of today's session was spent debugging subtle pipeline-mechanics bugs.
