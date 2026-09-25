---
id: REFAC-098
type: refactor
severity: medium
title: Move provider-native identity fields out of the generic target record
source: internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md
---

**Depends on:** REFAC-097.

**Related:** DEC-034

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`, § S10. The plan is authoritative for scope; this ticket carries the dependency and the acceptance criteria.

## Remediation

Move `provisioner_role_arn`, `cluster_access_role_arn`, `deploy_role_arn`, `operator_role_arn`, `state_lock_table` and `provisioner_impersonator` out of `Sol_cli_config.target` into a provider-owned field, without a universal provider-identity record. Last, because it changes target-file parsing.

## Acceptance criteria

- Existing target files parse unchanged, or the migration is explicit and documented (pre-alpha: no compat shims required).
- A GCP target carrying AWS role ARNs is unrepresentable or rejected at parse time.

## Completion notes (required)

- Demo/example: not applicable (cloud lifecycle internals) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.
