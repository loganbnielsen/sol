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
- Update `internal/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.

## Completion notes

**Premise verified (2026-09-24):** `rg -n 'declared_query_of' cli/sol/lib` on `main @ c91af060`
matched in `sol_cli_destroy_verification.ml` (the B2 recipes were present), so the work was
still missing.

**Deleted, not moved.**
- *Verification:* the per-kind recipes, `identity`, `query_of`, the `declared_*` family, the
  per-address provider verdicts, and ARN parsing. What survives in
  `Sol_cli_destroy_verification` is three evidence sources:
  - state emptiness, which is DEC-045's authority for every resource Terraform manages;
  - the residue sweep, for controller-created and abandoned objects Terraform never owned;
  - the retention probes, for the final snapshot and instance snapshots.
  `aws_error_code` and `gcp_absence_message` are kept only because the sweep and the retention
  probes still use them.
- *Inventory:* the `Sol_cli_cloud_destroy.resource` inventory keeps address, kind,
  deletion-protection state and the retention identifiers: `name` (read by the sweep) and
  `identifier` (the RDS instance). `arn`/`project`/`provider_id`/`region`, `region_of_zone`,
  `identities` and the destroy-time `declared_set`/read-only plan are gone.
- *Plan and Terraform modules:* `Sol_cli_terraform_plan.declared_of_plan_json` /
  `show_declared_and_record` and `Sol_cli_terraform.show_saved_plan_declared` are gone.
- *Exit code 3 collapsed:* a destroy that reaches verified absence exits 0. A degraded
  `Continue_to_destroy` preparation is printed as a warning (`warning: a preparation degraded
  and destruction continued -- ...`) and does not change the exit code.
- The RDS retention probe reads the instance name from state's `identifier` attribute. It no
  longer reads `id`, which in the current AWS provider is the DBI *resource* id (`db-...`,
  provider docs: "`id` - RDS DBI resource ID"). The offline harness fixture now records both.

**Surviving invariants keep executable evidence.**
- *Unit tests in `test_cloud_destroy.ml`:*
  - destroy never constructs (refused reconciliation never applies);
  - half-built destruction;
  - Block vs Continue;
  - bracketed elevation;
  - state-empty (`observation_with`);
  - retention (the `test_destroy_verification` retention cases).
- *Offline harness (`internal/ci/test_cloud_lifecycle_offline.sh`):*
  - retain-nothing and final-snapshot destroys;
  - the GCP refused-reconciliation run, which now asserts exit 0 plus the degradation warning;
  - the non-Terraform residue sweep: EBS volumes as a positive control, GCP peering.
  - A new negative assertion: no `aws eks describe-cluster`, `describe-addon` or
    `rds describe-db-instances` query runs for Terraform-managed resources.
- *SEC-008:* `show_and_record (SEC-008)` in `test_terraform_plan.ml` is unchanged, and the
  deleted read-only destroy-time plan was one fewer path that ran `terraform show -json`.
- *Qualification* keeps its own independent inventory. Nothing under `internal/qualification/`
  changed.

**Reduction (secondary).**
| File | Lines on `main` | Lines now |
|---|---|---|
| `sol_cli_destroy_verification.ml` | 1669 | 527 |
| `sol_cli_destroy_verification.mli` | 235 | 105 |
| `sol_cli_cloud_destroy.ml` | 803 | 652 |
| `sol_cli_terraform_plan.ml` | 456 | 260 |
| `cmd_cloud_tf.ml` | 4019 | 3855 |

- Product code: +208 / −2082 lines. Tests and CI: +183 / −2118 lines.
- REFAC-092 provider dispatch: 77 → 73. `sol_cli_destroy_verification.ml` leaves the
  allowlist.

**Bookkeeping.**
- Demo/example: not applicable. These are cloud lifecycle internals, with no `sol.toml`,
  manifest or app-author surface.
- Language parity (DEC-022): no application-facing impact. Destroy verification is CLI-side
  and language-neutral.
