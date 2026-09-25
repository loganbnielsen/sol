---
id: REFAC-093
type: refactor
severity: low
title: Remove the destroy sweep rows for resources Terraform manages (EIP, NAT gateway, ECR prefix)
source: internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md
premise: "! rg -q 'aws_no_elastic_ips|aws_no_nat_gateways|aws_ecr_prefix_probe' cli/sol/bin/cmd_cloud_tf.ml"
---

**Depends on:** DEC-045.

**Related:** INFRA-047, AUDIT-064

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`, § S5a. The plan is authoritative for scope; this ticket carries the dependency and the acceptance criteria.

## Remediation

Delete the rows of `aws_orphan_sweep` (`cli/sol/bin/cmd_cloud_tf.ml`) that check kinds Terraform manages and destroys: EIP, NAT gateway, ECR prefix. Keep controller-created and intentionally relinquished residue (LoadBalancer, PV disks, the GCP service-networking peering).

## Acceptance criteria

- The removed rows' tests go; the offline harness still exercises LB/PV/peering residue in both directions.
- Promote to `READY_FOR_ENGINEERING` only after DEC-045 records that the authority premise holds.

## Completion notes (required)

- Demo/example: not applicable (cloud lifecycle internals) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.
