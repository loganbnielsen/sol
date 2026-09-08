---
id: FEAT-018
type: feature
severity: high
source: DEC-006
branch: FEAT-018/early-hosted-billing-guardrails
worktree: ../sun-FEAT-018-early-hosted-billing-guardrails
---

Add early hosted billing guardrails.

**Depends on:** DEC-006, FEAT-016.

**Problem:** Early hosted customers can be billed with a simple cost-plus model,
but hosted resources should not be created without account ownership, payment
readiness, cost attribution, and spend guardrails.

**Goal:** Define and implement the minimum guardrails needed before hosted mode
can run real customer workloads.

**Remediation:**

1. Define the early cost-plus billing record shape.
2. Track account/environment ownership for provisioned resources.
3. Define required payment/account readiness before hosted environment creation.
4. Add spend cap, alert, and approval-threshold concepts.
5. Define what happens when a cap is reached.
6. Record enough usage/resource metadata to reconcile provider cost.
7. Document that this is an early-adopter model, not final pricing.

**Out of scope:**

- Polished invoices.
- Fine-grained per-service metering.
- Tiered pricing implementation.
- Payment processor integration unless explicitly chosen later.
- Automatic cloud-cost ingestion if manual reconciliation is sufficient for the
  first private customers.

**Acceptance criteria:**

- Hosted environments have account ownership before creation.
- A hosted account can have a spend cap and approval threshold.
- The system can identify resources/costs attributable to an environment.
- The early model supports cost-plus billing without promising final pricing.
- The design prevents unbounded spend for early adopters.

## Review — automated checks passed
All acceptance criteria met: billing guardrails, spend cap enforcement, cost attribution, early cost-plus billing record, and account/environment ownership all implemented and tested; build and all 17 hosted_model tests pass.
