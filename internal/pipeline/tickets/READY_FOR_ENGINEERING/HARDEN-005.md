---
id: HARDEN-005
type: verification
severity: medium
title: Cloud boundary fitness test, re-running the Azure-on-paper change surface with the guards at zero
source: internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md
---

**Depends on:** REFAC-093, REFAC-098.

**Related:** HARDEN-004

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`, § S11 and § End-state report. The plan is authoritative for scope; this ticket carries the dependency and the acceptance criteria.

## Remediation

Do not implement Azure. Repeat the boundary audit's Azure-on-paper test against the final code. Baseline: about 5 registration touches and about 45 edits to existing lifecycle code. Target: Azure roots + Azure capabilities + one registration arm + credentials + qualification, with no generic identity widening and no scattered lifecycle edits.

## Acceptance criteria

- The REFAC-092 provider-match and wildcard allowlists are at zero, or each residual entry is justified in one line.
- The end-state report in the plan's § End-state report is written, with evidence for every preserved invariant.

## Completion notes (required)

- Demo/example: not applicable (cloud lifecycle internals) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.
