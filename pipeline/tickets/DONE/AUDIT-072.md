---
id: AUDIT-072
type: audit-finding
severity: high
title: Establish recoverable production state and scoped administrative identities
source: production-readiness reviews 2026-09-16; expands the remote-state finding to the production state/access guarantee
---

**Depends on:** DEC-026, DEC-027.

## Production guarantee

Infrastructure/control state for the selected production target is encrypted,
recoverable and protected from concurrent mutation. Provisioning, application
deployment and administration use named, auditable identities with only the
permissions their roles require.

The original finding covered commented-out Terraform backends. That mechanism is
necessary but insufficient: the current AWS path also grants cluster-creator
admin and exposes a public API endpoint, while no customer-cloud production
contract defines operator/CI identities or recovery.

## Decision boundary

DEC-026 selects the one initial provider/substrate. This ticket implements that
path only; provider parity is not required for maturity A. Engineering must
resolve the concrete cloud IAM roles, control-plane access boundary, backend
bootstrap and recovery procedure for that selected target.

## Implementation scope

- Provision or require encrypted remote Terraform state with locking/concurrency
  protection and backup/version recovery.
- Make local state explicitly non-conformant and fail before a production apply.
- Separate named provisioning, deploy and ordinary operator/admin identities.
- Remove standing cluster-creator administration from the normal production
  path; document the narrowly scoped bootstrap/break-glass procedure.
- Enable provider and Kubernetes audit evidence needed to identify the acting
  principal.
- Keep hosted per-customer state, organization-wide IAM and fleet access out of
  scope.

## Conformance and acceptance criteria

- Two concurrent infrastructure mutations are serialized or one is rejected
  without corrupting state.
- A clean runner can recover the backend and produce a plan with no unintended
  recreation after the original runner and local files are removed.
- Recovery from a prior backend object version is exercised and documented.
- The application deploy identity cannot mutate infrastructure or grant itself
  cluster administration.
- The ordinary operator path does not rely on the cluster-creator credential.
- A representative infrastructure and application mutation can be attributed to
  its named principal in retained audit evidence.
- HARDEN-002 records the state recovery and identity-boundary results.

**Implementation versus evidence:** This ticket builds the selected target's
state/access bootstrap. HARDEN-002 performs destructive-safe recovery and
authorization checks against an isolated qualification target.

**Demo/example coverage:** Not an application-facing feature. Document the exact
production bootstrap and recovery commands for the selected provider.

**TypeScript parity:** Not applicable; this is below the framework boundary.

## Outcome (2026-09-17)

Implemented for the one qualified provider (AWS), per the agreed decisions;
destructive recovery and authorization checks remain HARDEN-002's.

- **Sol provisions the conformant state backend by default.** New root
  `cli/platform/infra/bootstrap` creates an S3 bucket with versioning, AES256
  encryption and a public-access block plus a DynamoDB `LockID` table. It is a
  separate root because Terraform cannot create its own backend. Bring-your-own
  is supported by declaring an equivalent backend.
- **Local/non-conformant state fails before a production apply.** The profile
  preflight's `remote_state` guarantee is a real target-side check: `state_bucket`
  and `state_lock_table` must both be declared, and an undeclared backend names
  the fix. The AWS module's commented-out backend remains for non-profile use.
- **Named identities, distinct from cluster-creator admin.** Target fields
  `provisioner_role_arn`/`deploy_role_arn`/`operator_role_arn` plus a restricted
  `cluster_endpoint_cidr`; the preflight's `scoped_operator_identities` guarantee
  fails closed when a role is missing or the CIDR is `0.0.0.0/0`.
- **Sol owns the IAM policy *contracts*, not role lifecycle.** The bootstrap
  root emits three least-privilege policy documents (provisioner / deploy /
  operator); the deploy contract explicitly denies infrastructure and IAM
  mutation and self-granted admin, and the operator creates the roles and
  supplies ARNs. Sol is deliberately not a general IAM lifecycle manager.
- **No standing cluster-creator admin.** `enable_cluster_creator_admin_permissions`
  is now `var.enable_cluster_creator_admin` (default `false`); bootstrapping and
  break-glass are a documented, scoped exception.
- **Public endpoint with an explicit CIDR allowlist is acceptable for maturity
  A.** `cluster_endpoint_public_access_cidrs` is driven by
  `cluster_endpoint_cidr`; private-only networking is recorded as a stronger
  future posture.
- **Exact commands and recovery procedure** are in
  `docs/deployment/production-bootstrap.md`: bootstrap, backend config, clean-runner
  recovery, prior-state-object-version recovery, and stale-lock handling.

Premise check: the AWS module had `cluster_endpoint_public_access = true` with
no CIDR restriction and `enable_cluster_creator_admin_permissions = true`, the
backend block was commented out, and no target-level state/identity contract
existed.

**Implementation versus evidence:** offline proof is the target-config parse
test, the preflight established/refuted tests (backend, roles, `0.0.0.0/0`), and
`terraform fmt`/`validate` on the new root. HARDEN-002 performs the destructive
recovery and authorization checks: concurrent-apply serialization, clean-runner
recovery, backend version recovery, deploy-identity deny-tests, and
principal-attributed audit evidence.

**Demo/example coverage:** the bootstrap and recovery commands are documented for
the selected provider; no real credentials or account IDs are committed beyond
clearly-placeholder ARNs.

**TypeScript parity:** Not applicable; this is below the framework boundary.
