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
