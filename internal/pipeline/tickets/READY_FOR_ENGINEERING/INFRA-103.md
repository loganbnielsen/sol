---
id: INFRA-103
type: infra
severity: medium
source: alpha.7 AWS qualification inventory, 2026-10-04
title: Make AWS qualification reconciliation and absence inventory accurate
---

**Depends on:** None.

## Premise verified

`internal/qualification/aws/live-row.sh` remains the AWS evidence owner. In the alpha.7 run, its recovery imported `aws_db_instance.postgres` although the resource lives in a module, so Terraform rejected the address. Its post-inventory also listed deleted NAT gateways and terminated instances as live residue.

## Remediation

Use the state/configuration's qualified database address for recovery. Exclude provider terminal states from the live-resource verdict while retaining raw responses as evidence.

## Acceptance criteria

- An orphaned RDS instance is attributed with a valid import address.
- `deleted` NAT gateways and `terminated` instances do not prevent an `ABSENT` verdict; live ones do.
- Offline harness checks cover both cases. Example impact: none; qualification machinery only. Language-parity impact: none.
