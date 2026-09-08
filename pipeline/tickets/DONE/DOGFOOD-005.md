---
id: DOGFOOD-005
type: feature
severity: high
source: product-planning-2026-06-11
branch: DOGFOOD-005/customer-cloud-contract
worktree: /home/lbendtly/Code/sun-DOGFOOD-005-customer-cloud-contract
---

Customer-cloud deployment contract validation.

**Depends on:** DOGFOOD-003.

**Problem:** Sun's non-hosted production promise depends on a clear boundary
between the app model, generated deployment plan, and customer-owned substrate.
The Terraform and manifest paths must support that boundary without becoming
the default user interface.

**Goal:** Validate the customer-cloud path as a substrate contract, not as a
hand-authored Terraform workflow.

**Remediation:**

1. Run `sun deploy --dry-run` and inspect the generated manifests for a dogfood
   workspace.
2. Run `sun deploy --emit-plan-to` and confirm the plan captures workloads,
   routes, secrets, migrations, topics, and environment target.
3. Run `sun deploy --emit-to` and confirm GitOps output is complete and stable.
4. Review `platform/infra/` against the substrate contract: cluster, registry,
   ingress, certs, secrets, observability, Postgres, Kafka.
5. Document where managed customer-cloud ends and exported self-managed begins.

**Acceptance criteria:**

- Customer-cloud docs explain the three ownership lanes.
- Generated deployment plans are complete enough to reason about deploys before
  applying them.
- Terraform is documented as substrate implementation/escape hatch, not the
  primary app interface.
