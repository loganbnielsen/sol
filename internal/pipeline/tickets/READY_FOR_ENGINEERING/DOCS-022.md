---
id: DOCS-022
type: docs-finding
severity: medium
title: Correct the HARDEN-004 records to show the Attempt 5 and 6 divergences were operator-created, and withdraw A1
source: internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md
---

**Depends on:** DEC-045.

**Related:** FND-0030, FND-0055, FND-0056, DEC-044, DEC-040, HARDEN-004

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`, § S3. The plan is authoritative for scope; this ticket carries the dependency and the acceptance criteria.

## Remediation

Add dated correction/supersession notes to the Attempt 5 and Attempt 6 records, FND-0030, FND-0055, FND-0056, DEC-044, and INV-DESTROY-1/4 in `docs/qualification/gcp-production-single-region-v1-matrix.tsv`. Preserve history: never silently rewrite a conclusion. Record the points listed in the plan's § S3, in particular:

- Attempt 5: the operator ran `terraform state rm` on the zone. Attempt 6: the operator force-unlocked a lock held by a live apply, then SIGTERM'd Terraform and its provider plugin (Attempt 6 transcript `cc1eb286…` lines 613–615; `~/sol-attempt6-evidence/`).
- The SIGPIPE-on-Sol-death route: **reproduced locally, fix pending (INFRA-076)**. Not "fixed".
- Independent provider inventory is qualification's responsibility; DEC-040 decides authorization de-escalation, not resource absence.
- A1 is withdrawn. FND-0030 is restated around what remains required: destroy never constructs; half-built targets stay destructible; divergence Sol cannot vouch for fails closed.

## Acceptance criteria

- Every listed record carries a dated note citing its evidence; no earlier text is deleted.
- `rg -n 'A1' internal/pipeline/tickets/BACKLOG/DEC-044.md` shows the withdrawal.

## Completion notes (required)

- Demo/example: not applicable (cloud lifecycle internals) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.
