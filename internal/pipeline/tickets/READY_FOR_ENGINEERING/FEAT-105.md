---
id: FEAT-105
type: feature
severity: medium
title: Make green CI the default merge gate with risk-based optional review
source: Logan merge-workflow decision (2026-09-28)
---

Make green CI the default merge gate with risk-based optional review

**Depends on:** None.

## Decision

Straightforward refactors, ticket filings, and documentation changes should merge
after focused author validation and required green CI, without mandatory adversarial
review loops or a SOLDEV-REVIEW marker. Enable GitHub squash auto-merge so these PRs
do not require repeated manual polling and ceremonial approval comments.

Retain targeted review for infrastructure, security, lifecycle/concurrency, and
substantial API changes, and whenever the operator requests it. Risk-based review
is an author/operator judgment, not a new classifier or approval bureaucracy.
Use draft PRs while an intentionally requested review is outstanding; do not queue
auto-merge until its actionable findings are resolved. Do not require repeated
fresh-reviewer rounds after a satisfactory targeted review.

## Evidence and premise

Verified 2026-09-28: soldev_merge.ml requires pr_review_approved before merge;
the work, review-worktree, quality-review, and PR workflows prescribe review gates
or repeated review loops; attempting gh pr merge --auto reports that repository
auto-merge is disabled. The repository documents a one-approval rule that its
solo owner cannot satisfy through self-approval.

Review has genuine value: PR #490 caught malformed Terraform values escaping as an
exception, #147 caught a no-op LoadBalancer cleanup, and #132 caught a demo port
collision despite green tests. Those support targeted review, not mandatory review
of every metadata change. PR #585 documents a marker posted after merging, so a
marker is not evidence that a review actually gated a merge.

## Remediation

- Remove the universal review-marker prerequisite from soldev pipeline merge;
  keep review commands and comments available when requested. Inspect all callers,
  listing/readiness messages, and tests so they agree on the new readiness contract.
- Require successful required CI on the current PR head before an immediate merge.
  Pending, failed, unavailable, or stale check results must not authorize one.
  Preserve dependency checks, ticket completion in the squash, and worktree isolation.
- Enable repository auto-merge and remove the unsatisfiable solo-author approval
  requirement without removing required status checks or PR-only protections.
  Implement the supported GitHub auto-merge path rather than another polling daemon.
  Auto-merge must wait for required checks; never treat an admin bypass as a substitute
  for independently verifying green CI on an immediate merge.
- Restore a lightweight docs-only CI path. The current classification skips product
  tests but still installs OCaml/opam dependencies, builds guard binaries, and runs
  unrelated mutation suites. Preserve relevant ticket/frontmatter/dependency checks
  without bootstrapping the product toolchain on every Markdown filing; reuse the
  authoritative parser rather than introduce a second ticket interpretation. Measure
  a real docs-only run: aim for about 15 seconds of validation work, recording runner
  queue/setup time separately. Keep the full checks for changes to code or CI itself.
- Update .agents/skills/work, review-worktree, quality-review, and self-review,
  AGENTS.md, CONTRIBUTING.md, and other tracked merge guidance to use the same policy.
  Update the user-level PR skill at ~/.codex/skills/pr/SKILL.md in the authorized
  local environment and record that non-repository change in completion notes.
- Keep author self-checks proportional to risk; optional review is not permission to
  skip tests, input validation, security controls, or explicit live-run authorization.

## Acceptance criteria

- A routine ticket PR with green required CI merges through soldev without a marker;
  pending/failed/missing checks prevent immediate merge, covered by focused tests.
- Review remains explicitly invocable, and a draft awaiting targeted review cannot
  auto-merge. No new bespoke risk-label or approval state machine is introduced.
- A real low-risk PR is queued for GitHub squash auto-merge and merges only after
  required CI succeeds; settings and the resulting merge are recorded as evidence.
- A Markdown-only filing takes the lightweight path, still rejects malformed tickets,
  and avoids product builds/tests and unrelated mutation suites. Mixed code/docs
  changes retain full CI, with classifier positive and negative controls.
- Skills and documentation no longer universally demand review markers, solo-owner
  approval, or fresh-reviewer loops. Existing operator-requested reviews are honored.
- Ticket changes still go through PRs, and implementation tickets move to DONE in
  their implementation squash, never in a separate bookkeeping commit.
- Demo/example: exercise the maintainer CLI in a runnable workflow example; no
  application demo change is needed because this changes maintainer tooling only.
- Language parity: no impact; merge orchestration is independent of app language.
