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

## Completion notes (2026-09-25)

- Removed `aws_ecr_prefix_probe`, `aws_no_elastic_ips` and `aws_no_nat_gateways` and their use in
  `aws_orphan_sweep` (`cli/sol/bin/cmd_cloud_tf.ml`). The sweep now covers what Terraform does not
  own: controller load balancers and PVC-created EBS volumes on AWS, and the abandoned peering on GCP.
  Per DEC-045, the removed kinds are Terraform-managed (`aws_ecr_repository` in the root; the EIP and
  NAT gateway in `terraform-aws-modules/vpc`), so the destroy plus the empty-state check is their
  authority. The live harness keeps its independent inventory.
- Offline harness: EBS is still queried and a residue still fails the destroy (the mutation loop,
  now EBS only). A new negative assertion says EIP, NAT and ECR are no longer queried, using the
  `describe-volumes` query in the same log as positive control. **Positive control of the assertion:**
  run against the `main` binary it fails with *"REFAC-093: the destroy sweep still queries a
  Terraform-managed kind: aws ec2 describe-addresses"*.
- Stale descriptions corrected: the sweep's header comment in `cmd_cloud_tf.ml`, and
  `docs/deployment/production-bootstrap.md` step 5.
- `dune test cli/sol/test/` exit 0; offline harness exit 0; `check_ocamlformat.sh --all` clean.
- Demo/example: not applicable. Language parity (DEC-022): no application-facing impact.
- For REFAC-092: this changes no provider-dispatch count (the removed probes contained no
  `Sol_cli_provider` constructor), so the allowlist is unaffected.
