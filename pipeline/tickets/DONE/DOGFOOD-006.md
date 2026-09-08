---
id: DOGFOOD-006
type: feature
severity: medium
source: product-planning-2026-06-11
branch: DOGFOOD-006/docs-reconciliation
worktree: /home/lbendtly/Code/sun-DOGFOOD-006-docs-reconciliation
---

Reconcile docs from dogfood findings.

**Depends on:** DOGFOOD-001, DOGFOOD-002, DOGFOOD-003, DOGFOOD-004, DOGFOOD-005.

**Problem:** The docs currently mix completed implementation notes, hosted
planning, and user-facing instructions. After dogfooding, the README, tutorial,
deployment docs, and roadmap need to reflect the tested path.

**Goal:** Convert dogfood findings into a coherent user-facing path and a
cleaner planning record.

**Remediation:**

1. Update README quickstart to match the tested fresh-install path.
2. Update TUTORIAL with the shortest successful local workflow.
3. Update deployment docs with the three deployment ownership lanes.
4. Update ROADMAP with dogfood results and next milestone.
5. Move detailed findings into project dogfood notes or follow-up tickets.

**Acceptance criteria:**

- A new reader can tell which path is local dev, managed customer-cloud,
  exported self-managed, and hosted.
- README and TUTORIAL do not contradict each other.
- ROADMAP reflects the next milestone after Dogfood Alpha.
