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
