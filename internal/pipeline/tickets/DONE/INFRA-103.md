---
id: INFRA-103
type: infra
severity: medium
source: alpha.7 AWS qualification H2, 2026-10-04
title: Exclude terminal AWS resources from qualification residue inventory
---

**Depends on:** None.

## Premise verified

Re-verified 2026-10-04 on the INFRA-107 head. `aws_inventory()` in
`internal/qualification/aws/live-row.sh` queried `Reservations[].Instances[].InstanceId` and
`NatGateways[].NatGatewayId` with no state filter, so a terminated instance or a deleted NAT
gateway — a provider record that is no longer a billable resource — was printed in the
residue list the alpha.7 campaign read as leftovers. There was no explicit verdict at all;
the inventory was free text.

## Remediation

The raw responses are retained as evidence, now carrying each resource's state, and
`aws_residue_verdict()` computes a per-class verdict: `ec2-instances` excludes `terminated`
and `shutting-down`, and `nat-gateways` excludes `deleted`, `deleting` and `failed`. Terminal
records read `ABSENT`; a live resource reads `PRESENT`; a read that fails or does not parse
reads `UNKNOWN`, never absence. The verdict is written to `aws-inventory-verdict.txt`, the
inventory returns its status, and `phase_destroy` fails when the inventory does not read
`ABSENT`, so live residue is not silently accepted.

## Acceptance criteria

- Deleted NAT gateways and terminated instances do not prevent an `ABSENT` verdict; live
  resources do.
- Offline harness checks cover both cases and unreadable inventory.
- Example impact: none; qualification machinery only. Language-parity impact: none.

## Checks

- `internal/qualification/aws/test-live-row.sh` — 99 passed, including new scenarios: a
  terminated instance and a deleted NAT gateway read `ABSENT` with the raw terminal records
  retained and nothing `PRESENT`; a live instance and a live NAT gateway read `PRESENT` and
  fail the verification; an unreadable inventory reads `UNKNOWN` and is never reported
  `ABSENT`.
- Mutation check: removing the terminal-state filters makes the `ABSENT` scenarios fail
  (4 assertions), so the fixtures are demonstrated capable of failing.
- `internal/ci/check_no_comments.sh` passes.

## Completion notes

The AWS residue verdict now matches the tri-state the run procedure already required: a
provider's terminal record is not a billable resource and does not turn a verified teardown
into residue, while a live resource or an unreadable read still does. The GCP harness's
tri-state inventory is unchanged. Example impact: none; qualification machinery only, no
demo or reference-application change. Language-parity impact: none.
