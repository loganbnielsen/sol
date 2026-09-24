# FND-0046 — Destroy's retention report is printed from the policy, not observed from the provider

- **Classification:** `VERIFIED_DEFECT`, against DEC-033 ("`sol cloud destroy` reports the
  artifacts it deliberately retained, by identifier") and ADR 0004's retention postcondition
- **State:** `OPEN`
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
