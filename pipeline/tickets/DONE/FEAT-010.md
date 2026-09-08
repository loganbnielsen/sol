---
id: FEAT-010
type: feature
severity: low
source: PRODUCT_ARCHITECTURE.md
branch: FEAT-010/hosted-executor-spike
worktree: ../sun-FEAT-010-hosted-executor-spike
---

Spike the Sun-hosted executor boundary after deployment plans are stable.

**Depends on:** FEAT-006, FEAT-008, DEC-001, DEC-002, DEC-003, DEC-007.

**Problem:** Sun-hosted deployment is a product direction, but implementing a control plane before the deployment plan stabilizes would force premature API decisions. Once plan construction, executors, environment targets, and serialization exist, the next useful step is to define the hosted executor boundary without building the whole hosted product.

**Goal:** Produce a thin hosted-executor spike that proves a deployment plan can be submitted or handed off without changing the application model.

**Remediation:**

1. Add a hosted executor interface behind a clearly experimental boundary.
2. Accept a serialized deployment plan as the input.
3. Stub or mock the hosted submission path.
4. Define the minimum response shape:
   - release id
   - environment id/name
   - status
   - service summaries
5. Add docs explaining that hosted execution is directional and not yet a supported production path.

**Out of scope:**

- Real hosting control plane.
- Authentication/account management.
- Billing.
- Managed clusters.
- Managed secrets.
- Build pipeline ownership.
- Domain/TLS automation.

**Acceptance criteria:**

- The codebase has an obvious extension point for Sun-hosted deployment.
- No local or customer-cloud behavior changes.
- Product docs remain honest that hosted mode is future-facing until the control plane exists.

**Decisions applied:**

- DEC-001: hosted deploy receives prebuilt image artifacts from customer CI.
- DEC-002: first hosted runtime is single-tenant per customer.
- DEC-003: deployment plans reference secret keys only; secret values are managed
  through Sun's secret-management surface.
- DEC-007: hosted submission returns Sun release/status concepts, not GitOps or
  Argo implementation details.

## Review — automated checks passed
Hosted executor spike correctly implements the experimental boundary: mock submission path, required response shape, no production behavior changes, honest docs.
