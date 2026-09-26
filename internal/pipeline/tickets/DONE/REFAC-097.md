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
- Update `internal/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.

## Completion notes

**Premise verified (2026-09-25):** on the REFAC-096 branch (`a21d922c`), retention and residue
were split across three modules:
- `cmd_cloud_tf.ml`: `retention_evidence`, `prepare_destruction_result`, the sweeps and the
  load-balancer drain, 8 provider-dispatch sites in all;
- `Sol_cli_destroy_verification`: the RDS query recipes and classifiers, and gcloud's
  404 subject rule;
- `Sol_cli_cloud_lifecycle`: the retention type and the Destroy policy vars.

**Done.**
- **The `Sol_cli_destruction.t` record** is what each provider answers for a destroy:
  - `prepare ~retention ~cluster_name ~state`, which settles what will be kept and lowers
    the guards. A provider that cannot honour the retention answers `Preparation_failed`
    with `Block_destroy` and the reason, which is GCP's "cannot retain anything".
  - `retention ~retention ~pre_destroy ~preparation`, which returns the provider's verdict
    on what it promised to keep.
  - `residue ~pre_destroy ~cluster`, which returns the provider's sweep of objects Terraform
    does not own.
  - `before_substrate_destroy`, which is AWS's load-balancer drain.
- **The provider modules** build that record. Their code was moved verbatim, by script:
  - `Sol_cli_aws_destruction`: the RDS preparation and its verification, the final-snapshot
    observation, the snapshot recipes and classifiers, and the load-balancer and EBS probes
    with the drain.
  - `Sol_cli_gcp_destruction`: the guard lowering and its verification, the "cannot retain"
    refusal, the peering probe, and gcloud's absence rule.
- **Generic code receives only verdicts:** no ARN, snapshot id recipe or self-link.
  - `Sol_cli_cloud_destroy.preparation` is provider-neutral: `Nothing_prepared | Prepared {
    retained : string option }`.
  - Sol still owns `destroy_retention`, and `policy_vars` maps it to each provider's guard
    variables.
- **Supporting moves:**
  - `apply_asserted`, `terraform_outcome` and `terraform_stdout` moved to
    `Sol_cli_terraform_steps`, so provider code can run asserted applies.
  - The registry module is renamed `Sol_cli_provider_registry`. It now selects both the
    cluster and the destruction record, and the dispatch guard excludes it by that name.

**Behaviour unchanged.**
- The offline lifecycle harness exits 0 in both retention directions: final snapshot kept
  (including the pending and then available path), retain-nothing (no instance snapshots),
  and GCP final-snapshot blocked.
- The full `dune test cli/sol/test/` passes. The classifier tests in
  `test_destroy_verification.ml` now call the provider modules.
- The CI guards pass: destroy completeness, gcloud interface, operator diagnostics, and the
  lifecycle, publisher-boundary, qualification-assertion and readiness tests.

**Sizes.**
| File | Before | After |
|---|---|---|
| `cmd_cloud_tf.ml` | 2791 | 1826 |
| `sol_cli_destroy_verification.ml` | 527 | 206 |

The new modules total 1356 lines.

**REFAC-092 ratchet:** provider dispatch went from 11 to 3. `cmd_cloud_tf.ml` went from 10 to
2 (`credentials_result`, credential readiness), and `sol_cli_config.ml` stays at 1
(`target_empty`'s default).

**Bookkeeping.**
- Demo/example: not applicable. These are cloud lifecycle internals.
- Language parity (DEC-022): no application-facing impact.
