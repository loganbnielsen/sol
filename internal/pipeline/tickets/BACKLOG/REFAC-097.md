---
id: REFAC-097
type: refactor
severity: medium
title: Move retention and non-Terraform residue behind provider capabilities returning Sol verdicts
source: internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md
---

**Depends on:** REFAC-096.

**Related:** DEC-033, INFRA-072

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`, § S9. The plan is authoritative for scope; this ticket carries the dependency and the acceptance criteria.

## Remediation

Retention: Sol owns `destroy_retention`; each provider answers `Supported { vars; observe : unit -> verdict } | Unsupported reason`, and `Unsupported` maps to `Block_destroy` as today. Residue: provider-private observation of things Terraform does not own, returning `Present | Absent | Unknown`. No universal snapshot model; generic code receives no ARN, self-link, resource ID or query recipe.

## Acceptance criteria

- Retention and residue behaviour unchanged (offline harness, both directions).
- Retention logic no longer spans three modules; the REFAC-092 allowlist shrinks.

## Completion notes (required)

- Demo/example: not applicable (cloud lifecycle internals) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.
