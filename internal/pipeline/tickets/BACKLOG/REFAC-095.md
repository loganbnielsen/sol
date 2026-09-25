---
id: REFAC-095
type: refactor
severity: medium
title: Introduce capabilities_of with the table-shaped provider capabilities
source: internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md
---

**Depends on:** REFAC-092, REFAC-094.

**Related:** HARDEN-005

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`, § S6. The plan is authoritative for scope; this ticket carries the dependency and the acceptance criteria.

## Remediation

Extract from call sites (no up-front module signature): Terraform roots and backend arguments, Terraform variables per target, readiness data (`platform_storage`, `readiness_invocations`), authority-window matchers and scope (`bootstrap_matchers`, `bootstrap_scope`, `reconciliation_scope`), guarded addresses. Concentrate provider selection in `capabilities_of`. Behaviour-preserving.

## Acceptance criteria

- The REFAC-092 allowlist shrinks; the new count is in the completion notes.
- A new provider fails explicitly at capability construction; nothing inherits another provider's behaviour.

## Completion notes (required)

- Demo/example: not applicable (cloud lifecycle internals) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.
