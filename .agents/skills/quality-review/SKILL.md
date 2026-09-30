---
name: quality-review
description: Optional targeted review of a Sol diff for architecture, type safety, reuse, boundaries, and test adequacy. Use when explicitly requested or selected for a high-risk change, not as a universal pre-PR gate.
---

# Targeted quality review

Routine refactors and metadata changes use focused author validation plus required
CI. This review is optional, selected for infrastructure, security,
lifecycle/concurrency, substantial API changes, or an operator request.

Keep the PR draft while a selected review is outstanding. Give one independent
reviewer the ticket, worktree, exact diff against origin/main, and applicable
architecture/type-audit contracts. Ask for concrete actionable findings, not
speculative redesign or pre-alpha compatibility shims. A clean result is valid.

**Reviewer independence.** "Independent" means a reviewer the author did not
prime — normally a subagent. If your harness has no subagent facility, do not
simulate independence: stop and report that the requested review could not run,
or, with the operator's agreement, do it yourself and label the result a
self-review. Never present a self-review as an independent one.

Prioritize correctness and safety, explicit invariants, dependency direction,
appropriate module ownership, accidental public API, existing helpers before
duplication, useful domain types, and behavior-focused test coverage. Check
documentation against implementation rather than its summary.

Fix actionable findings, rerun relevant validation, and confirm the fixes.
One satisfactory targeted review completes this workflow; do not demand a fresh
reviewer or repeat full-suite runs for every small correction. Another pass is
appropriate only for materially new risk or an explicit request.

Record what was actually reviewed and tested. Review comments, including
SOLDEV-REVIEW markers, are informational and never a universal merge prerequisite.
Mark the PR ready and queue auto-merge (the default) once selected findings are
resolved, then monitor it to completion.
