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
- Update `internal/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.

## Completion notes

**Premise verified (2026-09-25):** on the REFAC-097 branch (`4958c111`), `Sol_cli_config.target`
had `provisioner_role_arn`, `cluster_access_role_arn`, `deploy_role_arn`, `operator_role_arn`,
`state_lock_table` and `provisioner_impersonator` as flat fields, so every target carried every
provider's identity.

**The migration (explicit and documented; pre-alpha, no compat shim).**
- Provider-native keys move into the target's own provider block:
  - `aws:` takes `state_lock_table` and the four role ARNs;
  - `gcp:` takes `provisioner_impersonator`.
- A flat key is refused at parse time with its new location, for example: ``target key
  "state_lock_table" belongs to the aws provider: declare it as `aws.state_lock_table` inside
  the target block (REFAC-098)``. It is never silently ignored: a dropped lock table would be
  a concurrent-apply hazard.
- **A GCP target cannot carry AWS role ARNs.** A workspace may declare both blocks in a shared
  `sol.yml`, but each target reads only its own provider's block.

**How it reads.**
- `Sol_cli_config.target` has no identity fields. `Sol_cli_config.provider_field target key`
  reads the target's own block.
- The provider capabilities route the values (`own_vars`, `backend_config`, and the
  cluster-access role).
- New capability fields:
  - `sol_keys`: the keys Sol consumes, which are no longer passed through as `-var`s;
  - `state_locking`: the provider-block key naming the lock, or none where the backend locks
    natively;
  - `scoped_identities`: what production preflight requires.
- The registry passes the AWS provisioner role from the block.
- Preflight names the missing keys as `aws.<key>`. On GCP (not production-qualified) it no
  longer demands an AWS lock table or role ARNs.

**Evidence.**
- New tests in `test_config.ml`:
  - a flat key is refused, and the error names `aws.provisioner_role_arn`;
  - a GCP target that inherits a shared `aws:` block reads no role, and no AWS key reaches the
    GCP root, while the AWS target reads it (the positive control);
  - Sol-owned keys are not passed through: the lock table is not a `-var`, the role is routed
    exactly once, and an ordinary provider-block variable still passes.
- The existing fixtures in `test_config`, `test_profile`, `test_cloud_lifecycle` and
  `test_target_report` were migrated, and the full suite passes.
- The offline harness exits 0 with its migrated fixtures, including the finding-11 assertion
  that `deploy_role_arn` reaches the argv. Before the fixture was migrated, the harness
  failed with exactly the new migration error.
- `test-live-qual.sh` passes (24/0).
- Guards repointed to where the code now lives:
  - `check_operator_diagnostics.sh` and its mutation test, which still reproduces every
    rejection;
  - `check_gcloud_interface.sh`, which now checks that the gcp-block assignment is merged and
    read.

**Examples and docs updated.**
- `internal/qualification/aws/run8-aws-target.example.yml`, the runnable example target.
- `docs/deployment/production-bootstrap.md`, which gains a note on the refusal.
- `docs/guides/TUTORIAL.md` and `internal/qualification/aws/aws-run-procedure.md`.
- The GCP qualification harness's generated target (`internal/qualification/gcp/live-qual.sh`).
- `rg` finds no example workspace or scaffold template declaring these keys.

**Bookkeeping.**
- Language parity (DEC-022): no application-facing impact. Target files are operator
  configuration read by the CLI, whatever language the application uses.
