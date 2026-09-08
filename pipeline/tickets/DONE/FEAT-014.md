---
id: FEAT-014
type: feature
severity: medium
source: DEC-003
branch: FEAT-014/secret-management-cli
worktree: ../sun-FEAT-014-secret-management-cli
---

Add Sun secret-management commands.

**Depends on:** DEC-003.

**Problem:** Sun deployment plans can reference secret keys without exposing
secret values, but users do not yet have a Sun-native way to create, update,
list, or delete those secrets across local, customer-cloud/self-hosted, and
hosted environments.

**Goal:** Provide one secret-management UX that works across environment modes
while allowing different backends behind the same command contract.

**Remediation:**

1. Add `sun secret set <KEY> --env <env>` for creating/updating a secret value.
2. Add `sun secret list --env <env>` for listing available secret keys without values.
3. Add `sun secret delete <KEY> --env <env>` for removing a secret.
4. For local/customer-cloud mode, materialize values as Kubernetes `Secret`
   objects in the target environment.
5. Define the hosted-mode client boundary, even if the hosted API is initially
   stubbed or documented as future.
6. Ensure secret values are never printed, logged, serialized into deployment
   plans, or written to generated manifests.
7. Add tests for command parsing, secret key validation, redaction, and rendered
   secret references.

**Out of scope:**

- Building the hosted secrets UI.
- Vault, AWS Secrets Manager, or GCP Secret Manager integrations.
- Secret rotation policies.
- Team/account permission modeling.

**Acceptance criteria:**

- Users can self-serve secret create/update/list/delete through Sun commands.
- `sun secret list` shows keys only, never values.
- Deployment plans continue to expose only `secret_keys`.
- Local/customer-cloud behavior works without a hosted control plane.
- Hosted behavior has a clear API boundary for the future control plane.

## Review — automated checks passed
FEAT-014 secret management CLI fully implemented: all three commands present, secret values never printed/logged/serialized, key validation enforced, K8s Secret materialized, hosted stub defined, all 6 secret tests pass (plus 80 other tests). Minor: README/ROADMAP not updated with sun secret commands; legacy render() in sun_cli_manifest.ml omits secret_keys but is only used in parity test with empty secrets, not in production code path. hygiene/tickets/ change in worktree is a known process violation.
