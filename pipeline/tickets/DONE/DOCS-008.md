---
id: DOCS-008
type: audit-finding
severity: low
source: project/audits/2026-06-22_docs_audit.md
branch: DOCS-008/work-summary-stale-state
worktree: ../sun-DOCS-008-work-summary-stale-state
---

WORK_SUMMARY.md top-section ticket table and deployment-lane description are stale.

**Depends on:** None.

**Description:** The current-status table at the top of `docs/planning/WORK_SUMMARY.md` shows FEAT-020 as IN_PROGRESS and FEAT-021/022/023 as REVIEW; all are in `project/tickets/DONE/`. ALPHA-001, ALPHA-002, FEAT-024, HARDEN-001 are listed as READY_FOR_ENGINEERING but also in DONE. The deployment-lane description (lines 68-74) still names "Sun Hosted" as an active lane with `sun cloud deploy` as the interface, contradicting the 2026-06-22 refocus.

**Impact:** Engineers reading WORK_SUMMARY.md to orient to current project state see wrong ticket statuses and a product direction that has been reversed.

**Remediation:**
1. Update the status table at the top to reflect that all post-dogfood tickets are in DONE.
2. Replace the four-lane description with the three-lane model (Local Dev, Exported Self-Managed, Managed Customer Cloud — Sun Hosted removed/deferred).
3. Add a brief "2026-06-22" entry noting the managed-hosting layer removal and self-hosted refocus.

## Review — automated checks passed
All three remediation items addressed: ticket table updated to DONE, Sun Hosted lane removed with dated note, 2026-06-22 entry added; diff confined to WORK_SUMMARY.md; build clean.
