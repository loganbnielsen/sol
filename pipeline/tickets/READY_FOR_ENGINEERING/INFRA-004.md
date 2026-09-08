---
id: INFRA-004
type: feature
severity: medium
source: DEC-009's revisit trigger — filed alongside it, 2026-09-07
---

**Depends on:** DEC-008 (decided, not yet implemented).

Prototype DEC-008's hosted tenancy mechanism for real — a single, manually-provisioned customer VPC/cluster inside one Sol-owned AWS account — to prove the shared-account/per-customer-isolation model actually works before any hosted control plane or UI work references it.

**Description:** DEC-008 decided hosted infrastructure lives in one Sol-owned AWS account with a per-customer isolated VPC/cluster, provisioned through the same `platform/infra/aws` Terraform module `sol cloud apply` already uses, with per-customer Terraform state. None of that has ever actually been exercised in the "hosted" shape — every real AWS run so far (DOGFOOD-011, and the customer-cloud path generally) has been a single workspace applying its own Terraform directly, not a Sol-operated control plane provisioning *on behalf of* a customer into a shared account.

This is explicitly a narrow validation spike, not the hosted control plane itself:
- Provision two clusters into the same AWS account (simulating two hosted customers), each via its own Terraform state (e.g. two separate state keys/workspaces against the same `platform/infra/aws` module), and confirm they're genuinely isolated at the VPC/security-group level from each other.
- Confirm nothing in `platform/infra/aws`'s current design (naming, tagging, IAM scoping) assumes there's only ever one cluster per AWS account — check for hardcoded assumptions (e.g. anything not parameterized by `cluster_name`/`workspace_name` that would collide across two simultaneous deployments in the same account).
- Confirm AUDIT-064's teardown fix and the existing `verify_aws_destroy` checks correctly scope to *one* of the two clusters without disturbing the other when only one is torn down — this is a real, previously-untested multi-tenant-in-one-account scenario.
- Minimize cost and duration; this is a prove-it-works spike, not a standing environment — tear both down immediately after validating isolation.

**Remediation / acceptance criteria:**
- Two simultaneously-running, Terraform-isolated clusters exist in the same AWS account at once, confirmed genuinely network-isolated from each other.
- Any hardcoded single-cluster-per-account assumption found in `platform/infra/aws`/`platform/infra/base` is documented (and fixed, if small; filed as a follow-up ticket if not).
- A short report records what worked, what didn't, and whether DEC-008's mechanism as decided is actually sound — this is the concrete evidence DEC-009's revisit trigger is waiting on.
- Both clusters torn down and verified gone (AWS account checked directly afterward, matching the discipline established in AUDIT-064/DOGFOOD-011) before this ticket is considered done.

## Autonomous-loop note (2026-09-08)

Skipped in this pass of the autonomous ticket pipeline: this environment has no live AWS credentials (`aws sts get-caller-identity` → `NoCredentials`), and even with credentials, provisioning real billed AWS infrastructure (two EKS clusters) is a consequential, real-money action the user hasn't pre-authorized for autonomous execution — the session's merge authorization doesn't extend to cloud spend/provisioning. Left in `READY_FOR_ENGINEERING` for the user to pick up with real AWS access, or to explicitly direct otherwise.
