---
id: INFRA-103
type: infra
severity: medium
source: alpha.7 AWS qualification H2, 2026-10-04
title: Exclude terminal AWS resources from qualification residue inventory
---

**Depends on:** None.

## Premise verified

`internal/qualification/aws/live-row.sh` inventories all matching EC2 instances and NAT gateways without filtering their states. The alpha.7 campaign listed terminated instances and a deleted NAT gateway as leftovers.

## Remediation

Exclude provider terminal states from the live-resource verdict while retaining raw responses as evidence. Keep unknown/read failures distinct from absence.

## Acceptance criteria

- Deleted NAT gateways and terminated instances do not prevent an `ABSENT` verdict; live resources do.
- Offline harness checks cover both cases and unreadable inventory.
- Example impact: none; qualification machinery only. Language-parity impact: none.
