---
id: DOCS-007
type: audit-finding
severity: medium
source: project/audits/2026-06-22_docs_audit.md
branch: DOCS-007/roadmap-sun-hosted-removal
worktree: ../sun-DOCS-007-roadmap-sun-hosted-removal
---

ROADMAP.md Deployment Ownership Lanes table and Phase 7 notes reference the removed Sun Hosted direction.

**Depends on:** None.

**Description:** The Deployment Ownership Lanes table (line 68) lists "Sun Hosted | Sun | `sun cloud deploy`" as an active lane. `sun cloud deploy` and the entire managed-hosting layer were deleted on 2026-06-22. Phase 6 notes reference "Sun-hosted executor" and Phase 7 historical notes name `Sun_cli_hosted_executor` and `Sun_cli_hosted_model` — modules that no longer exist.

**Impact:** A developer reading ROADMAP.md gets a false picture of Sun's product direction and may look for code that doesn't exist.

**Remediation:**
1. Remove the "Sun Hosted" row from the Deployment Ownership Lanes table, or replace it with a brief struck-through entry noting it was removed in favour of the self-hosted model.
2. Replace the Phase 6 "Sun-hosted executor" forward reference with a note that the spike was removed.
3. Add a Phase 7 footnote: the hosted executor and model modules were deleted as part of the self-hosted refocus on 2026-06-22.

## Review — automated checks passed
All three remediation items addressed correctly; diff confined to docs/planning/ROADMAP.md; build passes; no new stale references.
