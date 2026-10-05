---
id: INFRA-118
type: infra
severity: high
source: AWS/GCP live qualification boundary audit 2026-10-05
title: Make AWS qualification teardown verification fail closed
---

**Depends on:** None.

## Premise verified

The AWS matrix requires H6 to independently prove EKS, VPC, RDS and orphaned EBS/ELB/EIP
resources are absent after teardown. The current `aws_inventory` in
`internal/qualification/aws/live-row.sh` writes broad `aws` describe/list output to
`aws-inventory.txt` but does not classify expected target resources or check the exit status of
each provider read. `phase_destroy` returns success when `sol cloud destroy` succeeds and the
inventory command completes, even if the output contains target resources or a read failed.
Consequently a residual target resource or unavailable AWS API query can be reported in evidence
without causing the live run to fail, so H6 is not enforced as a fail-closed verdict by the runner.

The GCP runner has explicit `PRESENT` / `ABSENT` / `UNKNOWN` probes and rejects `UNKNOWN` during
absence verification. AWS H6 and the alpha campaign also require independent provider reads;
Terraform state and Sol's destroy result are not absence proof.

## Remediation

Add an AWS target-scoped absence verifier for the disposable resource classes named by H6. Each
independent AWS API read must produce a typed `PRESENT`, `ABSENT` or `UNKNOWN` result. A non-zero
provider query, malformed response or incomplete required query is `UNKNOWN` and fails
verification. A resource still matching the attempt's target is `PRESENT` and fails verification.
Retain raw command output and the classified result as evidence.

Keep `verify` read-only and keep teardown on `sol cloud destroy`. Do not use Terraform state or
resource tags alone to establish absence; use AWS describe/list calls and correlate returned
resources with the target/account/attempt. Account for expected durable installation resources
separately so their intentional retention does not look like a target leak. Update H6 evidence
instructions and the active AWS test path.

## Acceptance criteria

- After destroy, the AWS live row exits successfully only when every required disposable class in
  H6 is independently observed `ABSENT` and all required reads succeeded.
- Any target resource remaining, any failed API read, or any unparseable response yields a
  non-passing result; `UNKNOWN` is never interpreted as absence.
- The verifier identifies the run's disposable resources without requiring those resources to
  exist, and distinguishes durable installation resources explicitly retained by the contract.
- `verify` performs no mutation. The only harness teardown path remains `sol cloud destroy`.
- Focused local fixture tests cover present, absent, unknown, malformed and durable-resource
  cases. They test the verifier's parsing and verdict logic, not a fake AWS lifecycle.
- H6 evidence names the independent AWS queries and records both raw output and verdicts.
- Example impact: none; qualification tooling. Language-parity impact: none.
