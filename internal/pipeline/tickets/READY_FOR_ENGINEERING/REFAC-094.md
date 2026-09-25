---
id: REFAC-094
type: refactor
severity: medium
title: Delete the runtime ownership and verification model (per-kind recipes, captured identities, B2, exit code 3)
source: internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md
premise: "! rg -q 'declared_query_of' cli/sol/lib"
---

**Depends on:** DEC-045, DOCS-022, INFRA-076.

**Related:** FND-0055, FND-0056, DEC-044, HARDEN-004

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`, § S5b and § Surviving destroy semantics. The plan is authoritative for scope; this ticket carries the dependency and the acceptance criteria.

## Remediation

Delete (do not move into provider modules) product-runtime machinery whose purpose is independently modelling Terraform-managed ownership: the per-kind recipes in `Sol_cli_destroy_verification`; `identity` and the `arn`/`project`/`provider_id`/`region` fields of `Sol_cli_cloud_destroy.resource`; ARN parsing, GCP self-link/project extraction, AWS error-code parsing and the GCP 404-subject rule where only that verification uses them; B2 (`declared_set`, `declared_query_of`, `gcp_declared_recipe`, `aws_declared_recipe`, per-address obligations, the destroy-time read-only plan); any A1 scaffolding. Collapse exit code 3 into exit 0 plus a warning. Slim the inventory to address, deletion-protection state and retention identifiers a surviving check needs.

## Acceptance criteria

- Every surviving invariant in the plan's § Surviving destroy semantics keeps executable evidence: destroy never constructs (one rule: no CREATE/REPLACE except the bootstrap-authority operation); half-built destruction; Block vs Continue; bracketed elevation; state-empty; retention; non-Terraform residue.
- SEC-008 still holds (plan JSON never reaches the run log).
- Qualification keeps its independent provider inventory.
- Line/module reduction reported (secondary).

## Completion notes (required)

- Demo/example: not applicable (cloud lifecycle internals) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.
