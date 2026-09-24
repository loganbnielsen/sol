# FND-0046 — Destroy's retention report is printed from the policy, not observed from the provider

- **Classification:** `VERIFIED_DEFECT`, against DEC-033 ("`sol cloud destroy` reports the
  artifacts it deliberately retained, by identifier") and ADR 0004's retention postcondition
- **State:** `FIXED_UNQUALIFIED` (INFRA-072, 2026-09-24: retention is reported from a typed
  observation — the promised snapshot must exist *and* the provider must report it
  `available`, and a retain-nothing destroy must find no manual or automated snapshot for
  its own captured database; both failure modes fail the command. Not exercised against a
  real provider — see the resolution note)
- **First identified:** 2026-09-23, by a second reviewer at `main @ f2e1773`; re-verified at
  `origin/main @ f3e9480b`
- **Derived ticket:** `INFRA-072`
- **Evidence class:** `STATIC`

## What is established

`retention_report ~retention ~destroy_snapshot_id`
(`cli/sol/lib/sol_cli_cloud_lifecycle.ml:1085-1097`) returns a fixed string per policy:

- `Retain_final_snapshot`: *"final snapshot X … the target outlives its compute"*;
- `Retain_nothing`: *"destroyed to Absent with no residual billable artifacts"*.

Neither claim is checked. The preparation verifies that *state* carries
`skip_final_snapshot=false`. Nothing verifies after the destroy that snapshot X exists and
is `available` (`aws rds describe-db-snapshots --db-snapshot-identifier X`), or that
`none` left zero manual snapshots and zero retained automated backups.

## Relationship to FND-0006

FND-0006 is `QUALIFIED`: one live run (HARDEN Run 7 Attempt 7) observed the `none`
postcondition. That qualifies the mechanism once. It does not make each destroy observe
its own outcome. DEC-033 names retention as the guarantee that must *block*, and it is the
one guarantee this command prints without looking.

## Remedy shape

Make the report take observed evidence as a typed value
(`Snapshot_present of id | Snapshot_missing | Unobservable of reason` / `No_residue |
Residue of ids`), and fail loudly on a missing snapshot or unexpected residue. Take the
snapshot id from the provider response, not from the requested identifier.

## Related

FND-0006, INFRA-041, DEC-033, ADR 0004, INV-RET-1/2.

## Resolution (INFRA-072, 2026-09-24 — HARDEN-004 step 5, PR #487)

`Sol_cli_cloud_lifecycle.retention_report` is deleted. Retention is now a field of the
post-destroy observation (`Sol_cli_destroy_verification.retention`), which carries the two
values the remedy shape asked for: `Retention_required_and_observed` /
`Retention_not_required` on one side, `Retention_violated` / `Retention_unknown` on the
other. `classify` puts a violation and an unverifiable observation into *different* lists and
fails on both, so the report can no longer be produced from the policy.

What is queried, and what makes it a failure:

- `final-snapshot` → `aws rds describe-db-snapshots --db-snapshot-identifier <id>`: the
  snapshot must exist **and** the provider must report its `Status` as `available`. An
  explicit `DBSnapshotNotFound` is `Retention_violated`; a status that is not `available`
  (including `creating`, observed for a bounded time and then given up on) is
  `Retention_unknown`. Both fail the command. An answer about a *different* identifier is not
  evidence about this one.
- `none` → `aws rds describe-db-snapshots --db-instance-identifier <captured instance>` (no
  `--snapshot-type`, which AWS documents as automated *and* manual): any snapshot returned is a
  `Retention_violated` naming it. An unreadable answer is `Retention_unknown`.
- GCP `none` → nothing is queried, because Cloud SQL deletes its backups with the instance; the
  report says exactly that instead of claiming "no residual billable artifacts", and the
  verified absence of the instance is the guarantee.

**One deliberate difference from the suggested remedy shape.** The identifier checked is the
one the *preparation* established (generated before destroy and recorded beside the saved
plan), not an identifier discovered from a post-destroy listing. The provider's answer must be
about that identifier and must say `available`, so the printed claim still rests on an
observation; a provider-side rename would therefore fail closed — reported as not observed —
rather than being silently accepted. RDS creates the final snapshot under exactly
`final_snapshot_identifier`, so this is a tighter rule rather than a gap, but it is a choice,
recorded here rather than left to be inferred.

**What remains unqualified.** The query has never run against a real provider: it is derived
from the AWS CLI's documented surface and exercised only against an offline stub
(`internal/ci/test_cloud_lifecycle_offline.sh`, scenarios `RDS_SNAPSHOT_MISSING`,
`RDS_SNAPSHOT_PENDING`, `RDS_SNAPSHOT_CREATING_ONCE`, `RDS_SNAPSHOT_RESIDUE`) plus the
retention cases in `cli/sol/test/test_destroy_verification.ml`. A live destroy is what would
move this to fully `QUALIFIED`, and HARDEN-004 step 5 authorizes no live operation (Attempt 7
stays closed).
