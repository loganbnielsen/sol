---
id: AUDIT-069
type: audit-finding
severity: high
title: Enforce production release safety across deploy, failure and rollback
source: production-readiness reviews 2026-09-16; expands the migration-order finding into the release-safety guarantee
---

**Depends on:** DEC-026, DEC-027.

## Production guarantee

A production deployment either becomes a verified recorded release or fails
without advancing the current-release claim. Rollback restores the last
compatible recorded artifact set. Application code is not rolled out against a
known-incompatible database migration state.

Existing boundary leases, render-before-apply, deployment attempts,
content-addressed release records and rollback verification are strong inputs.
The uncovered maturity-A gap is migration/deploy ordering, not a need to replace
the release model.

## Decision boundary

After DEC-027 selects the authority, engineering must decide the narrow migration
contract for that lane: orchestrate migrations as part of deployment, or verify
that the required expand/compatible migrations have already been applied. Do not
guess this in implementation and do not treat a generic `--skip` flag as the
contract.

## Implementation scope

- Represent enough migration compatibility state to make the chosen preflight
  check deterministic.
- Refuse before application mutation when the migration contract is unsatisfied.
- Preserve failure recording and the rule that failed rollout/verification never
  advances the current-release pointer.
- Make rollback use the recorded digests from FEAT-050 and retain the existing
  migration-boundary refusal.
- Implement only the production authority selected by DEC-027.
- Implement the selected `sol status/check` drift behavior: detect and report
  divergence for imperative ownership, or report controller reconciliation state
  for GitOps ownership.

## Conformance and acceptance criteria

- A normal deployment reaches a healthy recorded release and verified live state.
- An unsatisfied migration prerequisite fails before workload mutation and names
  the required operator action.
- A deliberately failed rollout records the failure and leaves the prior current
  release authoritative.
- Rollback restores the last compatible digest set and independently verifies
  the live workload set before moving the pointer.
- Repeating the same desired release is idempotent.
- HARDEN-002 runs deploy, failed deploy and rollback as live scenarios.

**Demo/example coverage:** Extend the production-profile example with one
compatible migration and one deliberately blocked migration case.

**TypeScript parity:** CLI/reconciliation behavior is language-neutral; migration
metadata must not depend on the application build system.
