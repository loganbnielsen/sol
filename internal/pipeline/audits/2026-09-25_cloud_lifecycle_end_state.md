# Cloud lifecycle simplification — end-state report (HARDEN-005)

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md` (§ S11,
§ End-state report). **Measured on:** the HARDEN-005 branch, stacked on REFAC-098 (#507). The
programme baseline is `main @ c91af060` (2026-09-24), before REFAC-094.

The plan's success criterion is: *Sol owns Sol semantics. Terraform owns Terraform semantics.
Provider implementations own provider semantics.* This report records how each part of that
now holds, and the evidence for it.

## Before

- **Sol modelled Terraform-managed ownership.** It had:
  - per-kind provider recipes;
  - captured ARNs and self-links;
  - B2 declared coverage, backed by a destroy-time read-only plan;
  - an exit code 3 for "absence reached, preparation degraded".
- **Provider knowledge ran through generic code.** It took the form of 77 qualified
  provider-constructor matches and two silent `| _` provider wildcards (the SEC-010 class).
  They sat in the CLI orchestrator, the lifecycle, config and preflight.
- **The cluster reached the lifecycle as `cloud_outputs`**, a variant with one constructor per
  provider, matched at 17 sites.
- **Retention spanned three modules**, with the command owning the AWS RDS snapshot logic.
- **The target record carried every provider's identity**, as flat fields that any target
  could set.

## After

**Sol owns** the Sol semantics, each in its own module:
- the lifecycle phases and transitions;
- the apply sequence (`Sol_cli_cloud_apply.execute`), with its bracketed bootstrap window;
- the destroy sequence (`Sol_cli_cloud_destroy.execute`), with its preparation policy (Block
  vs Continue);
- `destroy_retention` (DEC-033);
- the evidence model (`Sol_cli_destroy_verification`: state, sweep, retention, verdict);
- supervised Terraform execution (INFRA-076);
- the provider-dispatch ratchet (REFAC-092).

**Terraform owns** everything it manages. Following DEC-045, a successful destroy plus an empty
state is the authority for absence. Sol still asserts what it enforces over Terraform evidence:
a destroy never constructs, and the saved-plan assertions stay in `Sol_cli_terraform_plan`.

**Each provider owns** its semantics, behind a registry:
- `Sol_cli_provider_capabilities`, below the lifecycle, holds the table-shaped capabilities:
  - the platform root and address prefix;
  - the backend configuration;
  - the root variables, split into hooks that preserve argument order;
  - the Destroy guard variables;
  - the bootstrap matchers and scopes;
  - the guarded addresses;
  - production qualification;
  - the provider-block keys Sol consumes, the state-lock key, and the scoped identities.
- `Sol_cli_provider_registry`, above the lifecycle, selects each provider's:
  - cluster (`Sol_cli_cluster.t`: name, platform variables, identity check, kube access,
    readiness, bootstrap window);
  - destruction (`Sol_cli_destruction.t`: prepare, retention verdict, residue, pre-destroy
    glue);
  - credentials.
- The implementations live in `Sol_cli_{aws,gcp}_cluster` and `Sol_cli_{aws,gcp}_destruction`.
- Provider-native target configuration lives in the target's own `aws:` / `gcp:` block
  (REFAC-098).

## Deleted model

The following no longer exists:
- the per-kind recipes, captured identities and ARN/self-link parsing;
- B2 declared coverage and the destroy-time read-only plan;
- exit code 3 (REFAC-094);
- sweep probes for Terraform-managed kinds: EIP, NAT gateway and ECR (REFAC-093);
- the per-provider `cloud_outputs` variant (REFAC-096);
- the provider-shaped preparation type `Aws_prepared | Gcp_prepared` (REFAC-097);
- the flat provider identity fields on the target (REFAC-098).

## Provider change surface — the S11 Azure-on-paper test

This was measured rather than estimated. In a throwaway worktree of this branch, an `Azure`
constructor was added to `Sol_cli_provider.t` (along with `of_string`, `to_string` and `all`)
and the tree was built.

- **The compiler found exactly four sites,** all in the registry:
  - `Sol_cli_provider_capabilities.capabilities_of`;
  - `Sol_cli_provider_registry`'s three selections: cluster, destruction and credentials.

  With those four arms stubbed, the library, the command and the tests all compiled. No
  generic lifecycle code needed an edit.
- **Three tests failed at run time, and each asks for one of the planned items:**
  - `readiness predicates` validates every provider's readiness invocations, so it demands
    Azure capabilities. A new provider cannot be left unvalidated.
  - `unknown target provider` and `unknown provider box` used `azure` as their example of an
    unknown provider, so they need a different example name. That is test data, not coupling.

**The surface an Azure provider needs is therefore:**
- the Azure Terraform roots (`cli/platform/infra/azure`, plus a platform root);
- the Azure capabilities record and one arm in `capabilities_of`;
- `Sol_cli_azure_cluster` and `Sol_cli_azure_destruction`, with three registry arms;
- Azure credentials, as a function in the cluster module;
- qualification: the offline harness's per-root Terraform fakes, the live harness, and the
  two test-data renames.

**Nothing else changes:**
- **Identity:** no generic identity widening. Identity goes in an `azure:` target block.
- **Guards:** the one CI guard that hard-coded provider roots, `check_destroy_completeness.sh`,
  now derives them from the provider list (HARDEN-005). Its self-test proves that a new
  provider's root is checked without editing the guard.

**Against the baseline:** the boundary audit counted about 5 registration touches and about 45
edits to existing lifecycle code, plus one silent wildcard. The measured surface is now one type
and four arms in two registry modules, no generic edits, and no wildcards.

## Guards at zero

The REFAC-092 ratchet went from 77 qualified provider matches and 2 wildcards to **1 and 0**.
The one residual entry is justified in the allowlist:
- **`sol_cli_config.ml` (1):** `target_empty`'s placeholder provider in a partial, not yet
  resolved target record. `resolved_target` always overwrites it with the provider named by
  the target path.

The registry modules are excluded from the guard because selecting a provider's implementation
is their job.

## Complexity (secondary)

| File | Baseline (`c91af060`) | Now |
|---|---|---|
| `cmd_cloud_tf.ml` | 4019 | 1791 |
| `sol_cli_destroy_verification.ml` | 1669 | 206 |
| `sol_cli_cloud_lifecycle.ml` | 1616 | 1382 |
| `sol_cli_cloud_destroy.ml` | 803 | 654 |
| `sol_cli_terraform_plan.ml` | 456 | 260 |
| `sol_cli_config.ml` | 1475 | 1304 |

The new provider, registry and sequence modules total 3079 lines. Most of that is code moved
verbatim out of `cmd_cloud_tf.ml`. The main reduction is the deleted ownership model (REFAC-094
removed about 2080 product lines).

## Evidence the simplification did not weaken

| Invariant | Executable evidence |
|---|---|
| **Destroy never constructs** | `test_cloud_destroy.ml` "refused reconciliation never applies"; `Sol_cli_terraform_plan.guarded_apply` / `apply_asserted`, the saved-plan assertion used by every destroy-path apply; the offline harness's GCP refused-reconciliation run (the substrate destroy still runs, and the refused apply never does) |
| **Half-built destruction** | `test_cloud_destroy.ml` "half-built state" / "a half-built target must be destroyable"; the configuration ∩ represented-state eligibility (`preparations_eligible`), fed by the provider's `guarded_addresses` |
| **Block vs Continue** | `test_cloud_destroy.ml` Block_destroy / Continue_to_destroy cases; GCP's final-snapshot refusal (`Sol_cli_gcp_destruction.prepare`, `Block_destroy`) and its harness scenario |
| **Retention** | the offline harness, both directions: final snapshot kept (pending, then available), retain-nothing (no instance snapshots), GCP final-snapshot blocked; the classifier tests in `test_destroy_verification.ml` against `Sol_cli_aws_destruction` |
| **Privilege cleanup (bracketed elevation)** | `test_cloud_apply.ml`: a failure inside the window removes it exactly once, the sequence's own removal is never retried, a cleanup failure is reported next to the primary failure (a mutation that skips cleanup fails two cases); `test_cloud_destroy.ml` "elevated access opened/removed"; the harness's INFRA-061 / DEC-040 scenarios |
| **Abnormal-operation safety** | `test_supervised.ml`: clean run, Sol's death, interrupt, positive control (the #501 race fix), signal death, `errored.tfstate`, supervisor killed; the Running / Resolved / Unresolved guard in the harness |
| **Post-destroy state empty** | `test_destroy_verification.ml` state cases; the harness's 'terraform state (disposable root): empty' assertion |
| **Non-Terraform residue** | the harness's EBS volume positive control and GCP peering scenario, now observed by `Sol_cli_{aws,gcp}_destruction` |
| **Qualification independence** | nothing under `internal/qualification/` depends on the deleted product model; `check_qualification_transport.sh` and `test_qualification_assertions.sh` pass; the GCP live harness's generated target is migrated (REFAC-098) and `test-live-qual.sh` passes 24/0 |

None of the tickets in this programme ran a live cloud operation or touched real Terraform
state. Live qualification of the simplified code is the separately gated HARDEN-006 (GCP) and
HARDEN-007 (AWS).
