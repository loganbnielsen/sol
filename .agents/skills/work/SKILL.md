---
name: work
description: Implement or resume Sol tickets in isolated worktrees, validate proportionally, and submit CI-gated PRs with optional targeted review.
---

# Ticket worker

Resolve requested IDs with `soldev pipeline check <id>` and inspect live PRs with
`soldev pipeline ls`. Verify the ticket premise before implementing it. Unresolved
human decisions, dependencies, or stale premises stop pickup, not silently vanish.
Resume an existing branch/worktree/PR rather than duplicate interrupted work.

For actionable tickets without an existing tree, fetch and create an owned
worktree from `origin/main`. Never mutate the canonical checkout. Follow
CONTRIBUTING.md's isolation/ownership policy and name the tree on git mutations.

Implement the ticket's remediation, keeping changes behavior-preserving where
specified. Run focused tests and formatting/static checks; expand verification
for security, concurrency, infrastructure, or changed runtime contracts. Use the
testing skill for tests. Check the diff yourself before submitting.

Move the implementation ticket from READY_FOR_ENGINEERING to DONE in the final
implementation commit so the squash carries completion atomically. Explicitly
partial work keeps the ticket READY and declares `(<ID>, part A)` in its subject.
Record premise verification, checks, demo/example and language-parity impacts,
and remaining limitations in the ticket and work summary.

Use `soldev pipeline submit <id>` from the worktree to open/reuse the PR.
Routine refactors, documentation, and filings require no review-marker comment
or adversarial loop. **Queue GitHub squash auto-merge by default** with
`soldev pipeline merge --auto <id>`, as soon as the PR is non-draft and its
prerequisites are resolved. Do not wait for green and merge by hand; an immediate
merge (without `--auto`) is the exception. Drafts and unresolved prerequisites
cannot be queued. Then monitor the queued merge to completion and report whether it
merged — a queue request is not a merge. Local worktrees are preserved.

Choose targeted review for infrastructure, security, lifecycle/concurrency,
substantial API changes, or an explicit operator request. Keep that PR draft
until the review finishes and actionable findings are resolved; then mark it
ready and queue auto-merge. One satisfactory targeted review is sufficient;
fresh-reviewer loops are not the default. Do not invoke review skills merely
because they exist.

Report merged versus queued PRs accurately, with validation and any blockers.
A queue request is not a completed merge, and an optional marker is not proof
that review gated one.
