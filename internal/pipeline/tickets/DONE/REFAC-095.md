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
- Update `internal/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.

## Completion notes

**Premise verified (2026-09-25):** `rg -c 'capabilities_of' cli/sol` on `main @ 8637c1e0`
matched nothing. The provider matches this ticket names were still at their call sites.

**What moved.** `Sol_cli_provider_capabilities` holds one record per provider, and
`capabilities_of` is the only provider match. It is exhaustive with no wildcard, so a new
`Sol_cli_provider.t` constructor fails to compile until it declares its own record. Nothing
inherits another provider's behaviour. The record holds:
- the platform root and the platform-address prefix;
- the backend `-backend-config` values and the cluster-access role;
- the platform StorageClass and its CSI driver;
- the provider root's variables, as three staged hooks: provider-own fields,
  profile-derived vars, and root-declared vars (the ECR list stays lazy);
- the Destroy policy's guard variables;
- the bootstrap matchers, the bootstrap scope and the reconciliation scope;
- the guarded addresses;
- the substrate-ready expectation text;
- `production_qualified`, which replaced `qualified_providers = [ Aws ]` in the preflight.

`terraform_vars` moved from `Sol_cli_config` to `Sol_cli_terraform_vars.of_config`, since
`Sol_cli_config` sits below the capabilities it would need. `Sol_cli_config` now exports
`ecr_repositories_var`.

**Behaviour-preserving.**
- Variable order is unchanged. Profile vars (node shape, then `rds_deletion_protection`) and
  root-declared vars are prepended exactly as before, and every `terraform_vars` test in
  `test_config.ml` and `test_profile.ml` passes unchanged except for the renamed entry point.
- Full `dune test cli/sol/test/` passes, and the offline lifecycle harness exits 0.

**The REFAC-092 allowlist.**
- Provider dispatch goes from **73 to 44**:
  | File | Before | After |
  |---|---|---|
  | `cmd_cloud_tf.ml` | 44 | 34 |
  | `sol_cli_cloud_lifecycle.ml` | 19 | 7 |
  | `sol_cli_config.ml` | 7 | 1 (`target_empty`'s default) |
  | `sol_cli_profile_preflight.ml` | 1 | 0 |
- Wildcard provider arms go from **2 to 0**: the AWS-only production database protection
  and node shape are now AWS capability data. The registry is excluded from the guard next to
  `sol_cli_provider`, because selecting capabilities by provider is its job.
- What remains is `Aws_outputs`/`Gcp_outputs` (REFAC-096) plus credentials, retention,
  residue and preparation (REFAC-097).

**Guards that read moved code, repointed.**
- `check_destroy_completeness.sh` rule 3, which checks that every routed deletion guard is
  lifted by a Destroy policy. Positive control: with `sql_deletion_protection` renamed in a
  copy of the capabilities module, the check fails naming it.
- `check_production_infra.sh`, which checks the StorageClass literals.
- `check_operator_diagnostics.sh` and its mutation test, which check `operator_role_arn`
  routing. The mutation still reproduces the rejection.

**Bookkeeping.**
- Demo/example: not applicable. These are cloud lifecycle internals, with no `sol.toml`,
  manifest or app-author surface.
- Language parity (DEC-022): no application-facing impact. Provider capabilities are
  CLI-side and language-neutral.
