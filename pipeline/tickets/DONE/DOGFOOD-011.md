---
id: DOGFOOD-011
type: feature
severity: high
source: product-planning-2026-06-22
---

Real AWS dogfood: `sun cloud init --aws` through full ops loop.

**Depends on:** None.

## Problem

Every dogfood pass to date has run against a local k3d cluster. `sun cloud init --aws` wraps `terraform apply` on the modules in `platform/infra/aws/` but has never been executed against a real AWS account. The Terraform modules, ECR auth flow, kubeconfig setup, and `sun deploy` against a non-k3d cluster are all unproven.

## Goal

Prove the full self-hosted production path end-to-end in a real AWS account:

1. `sun cloud init --aws` — provisions EKS, ECR, RDS, Route53
2. Configure kubectl from the printed `kubeconfig_command`
3. `sun deploy --registry <ecr-registry> --image-tag <sha>` — build, push, apply
4. `sun migrate` — apply migrations against RDS
5. `sun status` — verify pods running
6. `curl` the deployed service endpoint
7. `sun logs`, `sun rollback` — verify ops loop

## Acceptance criteria

- All seven steps complete without manual workarounds
- Any blocking bugs are filed as READY_FOR_ENGINEERING tickets
- A dated dogfood report is written to `project/dogfood/`
- Terraform state and provisioned resources are destroyed after the run

## Open Questions

- **Which AWS account?** Need a real account with appropriate IAM permissions. This cannot be run in the local dev environment.
- **Cost estimate?** EKS + RDS + ECR for a short test run is roughly $5–10. Destroy immediately after.

## Blocked On

A real AWS account with IAM credentials in the environment.
