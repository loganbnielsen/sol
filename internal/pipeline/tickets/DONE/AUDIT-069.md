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

## Outcome (2026-09-17)

The migration-ordering gap is closed; the ticket's other acceptance criteria were
already implemented, so they are pinned by existing suites rather than
reimplemented.

**Decision (recorded here, per the ticket's "do not guess" boundary):** the
required compatible set is *every* migration in the workspace's `db/migrations` —
`required ⊆ applied` against the authoritative `sol_<workspace>_schema_migrations`
table. No target/`sol.yml` declaration of "which migrations matter": that would
be a third authority able to disagree with `db/migrations` and
`schema_migrations`. Accepted consequence: adding a file to `db/migrations` is a
declaration that it is a prerequisite for deploying that revision. The authored
`-- sol:disposition expand|contract` header (DEC-018/FEAT-066) is deliberately
*not* the marker for this: it answers whether a migration blocks a rollback, and
an expand migration is still required for code written after it.

**New behavior** (`Sol_cli_migration`, pure; `Cmd_migrate`/`cmd_deploy`, live):

- `Sol_cli_migration` holds the contract with no I/O: version parsing
  (`001_name.sql`), the required set (ordered; an unnumbered file is an error,
  not a silent skip), `unsatisfied = required \ applied`, and the JSON encoding.
- `sol migrate status --json` emits the machine-readable applied set; the pure
  module owns the encoding so the writer and the reader cannot drift.
- The deploy path runs **static preflight → live migration-status verification →
  workload mutation** (`check_migration_prerequisite`, after the preflight and
  before the boundary lease/apply). The live step submits a short-lived
  **read-only** Job (`sol migrate status --json`; it only SELECTs
  `schema_migrations`), reads its logs, and removes the Job/ConfigMap either way —
  reusing the FRIC-012 in-cluster model, so no direct operator/CI DB
  reachability is needed.
  - *Satisfied* → proceed. *Unsatisfied* → fail before mutation, naming the
    missing migrations and `sol migrate apply <target>`. *Unavailable* (Job
    cannot run, DB/table unreadable) → **fail closed**, never a cached Sol-side
    record.
- `--dry-run`/`--emit-to` create no Job and no other cluster object, and report
  the prerequisite as **not verified** — never as established.
- Applies only when a production profile is selected; a workspace with no
  `db/migrations` requires nothing; `sol deploy` never applies migrations.

**Existing behavior, pinned rather than rebuilt:**

- A failed deployment attempt is never a recorded release
  (`test_deployment_attempt.ml`; `cmd_deploy` records only on `Ok`), so the prior
  current release stays authoritative.
- Rollback verifies the live workload set before moving the pointer, retaining
  the migration-boundary refusal (`test_rollback.ml`).
- Idempotency of the same desired content (`test_release_id.ml`).
- DEC-027 drift reporting already exists for the selected imperative authority:
  `Sol_cli_rollback.unexpected_workloads` (FEAT-074) is consumed by
  `sol deploy`/`sol up`. No follow-up ticket is needed.

**Implementation versus evidence:** offline proof is `test_migration.ml` (subset
contract, version parsing, unnumbered-file refusal, JSON round-trip) plus the
existing suites above. HARDEN-002 must run the live scenarios: migrations applied
(deploy succeeds), a required migration missing (fails before mutation), an
unreachable DB (fails closed), and `--dry-run` (succeeds, creates nothing).

**Known cost / follow-up consideration:** the read-only status Job reuses the
same freshly built `sol-cli-migrate` image as `sol migrate apply`, so a
production deploy in a workspace with migrations now pays that build/push (Docker
layer caching makes repeats cheap). A pinned, prebuilt status-checker image would
remove it; not required by this ticket and not a blocker.

**Demo/example coverage:** `examples/pluto` —
`db/migrations/0001_notifications.sql` is the compatible case; the README
documents the deliberately blocked case (add a migration without applying it) and
the dry-run report.
