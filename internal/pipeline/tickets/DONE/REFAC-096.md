---
id: REFAC-096
type: refactor
severity: medium
title: Replace the Aws_outputs and Gcp_outputs dispatch with opaque cluster access
source: internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md
premise: "! rg -q 'Aws_outputs|Gcp_outputs' cli/sol/lib/sol_cli_cloud_lifecycle.mli"
---

**Depends on:** REFAC-091.

**Related:** HARDEN-005

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`, § S8. The plan is authoritative for scope; this ticket carries the dependency and the acceptance criteria.

## Remediation

Replace `Sol_cli_cloud_lifecycle.cloud_outputs` (17 dispatch sites in `cmd_cloud_tf.ml`) with the smallest abstraction apply and destroy need: cluster name/handle, kube environment, platform variables. Provider output records and parsing stay provider-private. No universal output record of optional fields.

## Acceptance criteria

- No `Aws_outputs`/`Gcp_outputs` outside provider modules; REFAC-092 allowlist shrinks.
- Behaviour-preserving: the offline lifecycle harness is unchanged in outcome.

## Completion notes (required)

- Demo/example: not applicable (cloud lifecycle internals) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.

## Completion notes

**Premise verified (2026-09-25):** on `main @ b2adb21b`, the ticket's own probe `rg -q
'Aws_outputs|Gcp_outputs' cli/sol/lib/sol_cli_cloud_lifecycle.mli` matched, so the variant was
still the lifecycle's cluster type. On this branch the probe no longer matches, and `rg -n
'Aws_outputs|Gcp_outputs' cli/sol` matches nothing.

**Done.** `Sol_cli_cluster.t` is the opaque cluster handle. It holds:
- the cluster's name;
- the provider's share of the platform variables (fixed, then ordered optional entries, so
  argument order is unchanged);
- the identity check;
- a polymorphic `with_access` giving an ephemeral provisioner kubeconfig;
- `ready`;
- the bootstrap window: `Verified { gate; observe; deescalated; principal }` on AWS with a
  provisioner role, `No_role_declared`, or `Closed_by_platform_root` on GCP.

The provider modules (`Sol_cli_aws_cluster` and `Sol_cli_gcp_cluster`) build that record. The
code moved into them was extracted by script, verbatim, from `cmd_cloud_tf.ml` and
`Sol_cli_cloud_lifecycle`:
- the outputs records and parsers;
- the kubeconfig builders;
- the whoami gate, window control and de-escalation probes;
- the readiness checks.

The only edits are the references the move required, plus comments naming mechanisms that no
longer exist. `Sol_cli_provider_clusters.of_root` selects the provider's builder. It sits one
layer above the lifecycle, because the cluster modules use the lifecycle's DEC-040 model, and
the dispatch guard treats it as part of the registry, next to `Sol_cli_provider_capabilities`.

**Behaviour.**
- The offline lifecycle harness exits 0 and the full `dune test cli/sol/test/` passes.
- A new test covers the identity check behind the handle: a different role is refused, and
  the declared role is accepted as the positive control.
- Two deliberate changes:
  1. The GCP residue sweep reads the project from the target's `gcp.project_id`, the variable
     the root receives. The root's `project_id` output only echoes it. The harness target
     declares it.
  2. A destroy with no install outputs now prints `bootstrap window: not observed (no install
     outputs ...)`. On AWS it used to print "no provisioner role declared", which was untrue
     there. Nothing asserts on either line.

**Guards that read moved code, repointed.** `check_gcloud_interface.sh` now reads
`sol_cli_gcp_cluster.ml`. Positive control: adding `--kubeconfig` to the moved argv fails it
with the Attempt 2 message.

**Sizes.**
| File | Before | After |
|---|---|---|
| `cmd_cloud_tf.ml` | 3627 | 2791 |
| `sol_cli_cloud_lifecycle.ml` | 1588 | 1382 |

The new modules total 1116 lines.

**REFAC-092 ratchet:** provider dispatch went from 43 to 11. `cmd_cloud_tf.ml` went from 33 to
10, the lifecycle `.ml`/`.mli` from 7 and 2 to 0 (both entries removed), and
`sol_cli_config.ml` stays at 1.

**Bookkeeping.**
- Demo/example: not applicable. These are cloud lifecycle internals.
- Language parity (DEC-022): no application-facing impact.
