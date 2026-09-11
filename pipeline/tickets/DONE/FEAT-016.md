---
id: FEAT-016
type: feature
severity: high
source: DEC-002
branch: FEAT-016/hosted-account-environment-model
worktree: ../sun-FEAT-016-hosted-account-environment-model
---

Define the hosted account and environment model.

**Depends on:** DEC-002, DEC-004, DEC-006.

**Problem:** Hosted deploy, secrets, release history, diagnostics, and billing all
need a shared ownership model. Today the deployment plan has workspace and
environment fields, but there is no hosted account/project/environment model that
ties a customer to a single-tenant runtime substrate.

**Goal:** Define the minimum hosted model for accounts, projects, environments,
and customer-scoped runtime targets.

**Remediation:**

1. Define the hosted identity hierarchy:
   - account/customer
   - project/workspace
   - environment
   - runtime substrate
2. Define stable identifiers for each object.
3. Define how a deployment plan maps to a hosted environment.
4. Define what metadata is required for release history, secrets, spend controls,
   and diagnostics.
5. Add an experimental serialization or in-memory model if useful for FEAT-010.
6. Document what is intentionally not implemented yet.

**Out of scope:**

- Authentication and authorization.
- Billing provider integration.
- Real hosted database/control-plane persistence.
- Team membership and RBAC.
- Provisioning real customer clusters.

**Acceptance criteria:**

- FEAT-010 can attach a hosted release submission to a customer/project/environment.
- FEAT-014 can target environment-scoped secrets.
- FEAT-015 can report release diagnostics with the right ownership context.
- FEAT-018 can attribute early costs to an account/environment.
- The model does not affect local or customer-cloud deploy behavior.

**Implementation:**

- Added `Sun_cli_hosted_model` with account, project, environment, runtime,
  secret-scope, and release-target types.
- Enforced single-tenant hosted runtime semantics at the model boundary.
- Added release-target validation against `Sun_cli_deployment_plan.t` for
  workspace, environment, mode, and ownership consistency.
- Added JSON serialization for release targets and secret scopes.
- Documented the experimental hosted ownership hierarchy and explicit deferrals.

## Review — automated checks passed
FEAT-016 fixes the cross-account runtime path in make_environment and adds a regression test; build and hosted model tests pass with no merge-blocking issues found.
