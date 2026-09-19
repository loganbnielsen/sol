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
