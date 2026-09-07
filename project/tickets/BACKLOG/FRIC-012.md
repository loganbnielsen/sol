---
id: FRIC-012
type: dogfood-finding
severity: high
source: project/dogfood/RUN_2026-09-07_AWS.md (DOGFOOD-011, first real AWS dogfood run)
---

**Depends on:** None.

`sol migrate` has no documented or tooled way to reach a properly-private production RDS instance — the ops loop's migration step doesn't actually work against a realistically-secured database.

**Description:** `platform/infra/aws/main.tf`'s RDS instance is correctly `publicly_accessible = false` (the default; never explicitly overridden) with a security group scoped to VPC-internal ingress only (`main.tf:180-192`) — this is the *correct*, secure configuration for a production database. Confirmed live during DOGFOOD-011: `sol migrate apply`, run from an operator's local machine (outside the VPC), failed with a clean `Connection timed out` after ~2 minutes. Direct `nc`/`aws rds describe-db-instances` confirmed there is genuinely no network path — not a firewall misconfiguration, a structural one (no public IP, no VPN, no bastion, no SSM tunnel set up by any part of Sol's tooling).

**Impact:** DOGFOOD-011's own acceptance criteria require `sol migrate` to complete as part of the ops loop, "without manual workarounds." As currently designed, this is only possible if RDS is made publicly accessible (a real security regression a user might be tempted to make just to unblock migrations) or if the operator independently sets up their own bastion/VPN/SSM bridge (undocumented, not part of Sol's story at all). Every real customer following the documented golden path to a secure production AWS deployment will hit this exact wall the first time they try to run a migration.

**Not yet determined:** the right mechanism. Options, roughly in order of how AWS-idiomatic they are:
1. **SSM Session Manager port-forwarding** through a small bastion instance (or a Fargate task) that Terraform provisions alongside RDS, with `sol migrate` (or a new `sol migrate --tunnel`/similar flag) wrapping `aws ssm start-session --document-name AWS-StartPortForwardingSessionToRemoteHost` transparently.
2. **Run migrations from inside the cluster** — a one-shot Kubernetes Job (using the same image/`POSTGRES_URL` secret already deployed) that `sol migrate` triggers and streams logs from, rather than connecting directly from the operator's machine at all. This sidesteps the network problem entirely and may be the more idiomatic fit given Sol already manages the cluster.
3. Document a bastion/VPN setup as a prerequisite and accept it as outside Sol's scope — weakest option, contradicts the "no manual workarounds" acceptance bar this ticket's parent (DOGFOOD-011) set for itself.

Whoever picks this up should evaluate these against how CI/CD is expected to run migrations too (a GitHub Actions runner has the exact same external-network problem a laptop does) — option 2 (in-cluster Job) likely generalizes better to that case than a bastion tunnel would, since CI environments can't easily hold an SSM session open either.

**Remediation:** Design and implement one of the above (or a better option), then re-verify against a real AWS deployment (per DOGFOOD-011's own pattern) that `sol migrate` completes without any manual network setup.
