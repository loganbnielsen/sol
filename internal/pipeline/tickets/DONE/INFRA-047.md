---
id: INFRA-047
type: bug
severity: medium
title: verify_aws_destroy does not check elastic IPs, NAT gateways or EBS volumes
source: audit finding FND-0003 — the AWS absence row rests on an operator sweep
---

**Related:** FND-0003
(`internal/pipeline/audits/findings/FND-0003-authority-and-absence-qualification-gaps.md`),
matrix row H6, `docs/deployment/production-bootstrap.md` (which records the same
gap), `cli/sol/bin/cmd_cloud_tf.ml` (`verify_aws_destroy`), AUDIT-064 (added the
load-balancer check), DEC-033 (the retention half of the same "cost-clean" claim).

## The gap

`verify_aws_destroy` checks EKS, RDS, ECR and — since AUDIT-064 — load balancers.
`production-bootstrap.md` records that **elastic IPs, NAT gateways and EBS
volumes are only manually swept**. Every AWS run's "cost-clean" claim therefore
rests partly on an operator step, not on the verifier. Run 7's independent sweep
found EIP/LB/EBS/VPC/ECR empty, but that was the harness's check, not the
verifier's.

## What to do

Extend `verify_aws_destroy` to cover, in the same fail-closed shape as the
existing checks:

- elastic IPs (unassociated and target-associated),
- NAT gateways, and
- EBS volumes (at least those carrying the target's tags).

## Acceptance criteria

- The verifier reports each of the three and fails closed on a positive result.
- The offline harness exercises both directions (resource present → verification
  fails; absent → passes), mutation-tested, so the new checks are demonstrably
  able to fail (HARDEN-003).
- The `production-bootstrap.md` rows that list the manual sweep are updated.

## Out of scope

GCP absence coverage, which was repaired separately in #363 (`gcp_absence_message`
now recognises gcloud's real 404 wording).

**Demo/example coverage:** Not applicable.

**TypeScript parity:** No language-parity impact.

## Implementation

`verify_aws_destroy` now queries target-named elastic IPs and NAT gateways and
target-tagged EBS volumes after Terraform destroy.  Each check reports its own
resource class, rejects a non-empty result, and fails closed on AWS CLI errors.

The offline lifecycle harness requires all three empty-result queries on a
successful destroy, then mutates each result independently to contain a residual
resource and requires the public destroy command to fail with the corresponding
diagnostic.  This exercises both directions without provider access.

### Why the `tag:Name` filters can actually match

The EIP and NAT checks select on `Name=tag:Name,Values=<cluster_name>-*`. That
looks like it could be a check that never fires, so it was verified against the
module that creates those resources: `terraform-aws-modules/vpc/aws` v5.7.0 and
v5.8.1 both tag `aws_eip.nat` and `aws_nat_gateway.this` with
`Name = "${var.name}-%s"`, and `cli/platform/infra/aws/main.tf` passes
`name = var.cluster_name`.  The filter therefore matches the resources this root
creates, for both the single-NAT and HA shapes.  EBS volumes are selected by the
standard `kubernetes.io/cluster/<cluster>` tag the CSI driver applies.

What the offline harness cannot show is that a *real* leftover matches these
filters; the first run that exercises this verifier should plant or observe one
residual of each class, as HARDEN-003 requires of any absence check.


## Landed (2026-09-20)

Merged in #376. `verify_aws_destroy` now fails closed on residual elastic IPs, NAT gateways
and EBS volumes. The offline lifecycle harness requires all three queries on a successful
destroy (so a missing check cannot pass on the mock's empty default) and mutates each
residual class in independently.

The `tag:Name` filters were verified against the module that creates the resources:
`terraform-aws-modules/vpc/aws` v5.7.0 and v5.8.1 name both `aws_eip.nat` and
`aws_nat_gateway.this` `<cluster>-<az>`, and the root passes `name = var.cluster_name`.

**Outstanding (behavioural):** Run 8 should plant or observe one residual of each class, so
the check is demonstrated able to fire against real resources rather than only against the
harness mock (HARDEN-003).
