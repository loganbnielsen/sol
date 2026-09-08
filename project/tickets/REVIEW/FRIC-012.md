---
id: FRIC-012
type: dogfood-finding
severity: high
source: project/dogfood/RUN_2026-09-07_AWS.md (DOGFOOD-011, first real AWS dogfood run)
branch: FRIC-012/migrate-in-cluster-job
worktree: ../sun-FRIC-012-migrate-in-cluster-job
pr: https://github.com/loganbnielsen/sol/pull/146
---

**Depends on:** None.

`sol migrate` has no documented or tooled way to reach a properly-private production RDS instance — the ops loop's migration step doesn't actually work against a realistically-secured database.

**Description:** `platform/infra/aws/main.tf`'s RDS instance is correctly `publicly_accessible = false` (the default; never explicitly overridden) with a security group scoped to VPC-internal ingress only (`main.tf:180-192`) — this is the *correct*, secure configuration for a production database. Confirmed live during DOGFOOD-011: `sol migrate apply`, run from an operator's local machine (outside the VPC), failed with a clean `Connection timed out` after ~2 minutes. Direct `nc`/`aws rds describe-db-instances` confirmed there is genuinely no network path — not a firewall misconfiguration, a structural one (no public IP, no VPN, no bastion, no SSM tunnel set up by any part of Sol's tooling).

**Impact:** DOGFOOD-011's own acceptance criteria require `sol migrate` to complete as part of the ops loop, "without manual workarounds." As currently designed, this is only possible if RDS is made publicly accessible (a real security regression a user might be tempted to make just to unblock migrations) or if the operator independently sets up their own bastion/VPN/SSM bridge (undocumented, not part of Sol's story at all). Every real customer following the documented golden path to a secure production AWS deployment will hit this exact wall the first time they try to run a migration.

**Decided mechanism:** run migrations from inside the cluster — a one-shot
Kubernetes Job (`sol migrate` triggers it, using the same image and
`POSTGRES_URL` secret already deployed, and streams its logs back) rather
than connecting to RDS directly from the operator's or CI runner's machine.

This was chosen over an SSM Session Manager bastion tunnel and over
documenting a bastion/VPN as an accepted prerequisite:
- It sidesteps the network-reachability problem entirely instead of working
  around it, so there's no new standing infrastructure (no bastion instance
  to provision, patch, or pay for).
- It generalizes to CI/CD for free: a GitHub Actions runner has the exact
  same external-network problem a laptop does, and can't hold an SSM session
  open the way an interactive operator could — a Job triggered via the k8s
  API has no such constraint.
- It reuses infrastructure Sol already owns and operates (the cluster, the
  deployed image, the existing secret) rather than teaching Sol a second
  standing-infra pattern just for migrations.

**Remediation:** Implement `sol migrate` as a Job-triggering command: render
a one-shot `batch/v1` Job manifest reusing the target service's image and
`POSTGRES_URL` secret reference, submit it via the k8s API, stream its pod
logs back to the caller, and surface the Job's exit status as `sol migrate`'s
own exit status. Re-verify against a real AWS deployment (per DOGFOOD-011's
own pattern) that `sol migrate` completes without any manual network setup,
from both an operator's machine and a CI runner.
