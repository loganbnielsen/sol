---
id: INFRA-072
type: bug
severity: medium
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

Destroy must observe retained artifacts before reporting them

**Depends on:** REFAC-091.

**Finding:** FND-0046 (`internal/pipeline/audits/findings/`).

**Sequencing:** this is step 5 of the HARDEN-004 order in `internal/pipeline/audits/HARDEN-004-handoff.md` ("The order now"). Coordinate with the HARDEN-004 owner; land it as that step, not in parallel.

**Premise verified 2026-09-23** against `origin/main @ f3e9480b` while filing (see the finding for the command/probe and observed output).

## Problem

`retention_report` prints "final snapshot X" or "no residual billable artifacts" from the policy; nothing checks the snapshot exists/`available` or that `none` left no snapshots or retained automated backups (ADR 0004 postcondition). FND-0006 qualified the mechanism once; each destroy still reports on faith.

## Remediation

After destroy, query the provider (`aws rds describe-db-snapshots …`, automated backups) and pass typed evidence to the report; a missing snapshot or unexpected residue fails the command.

## Acceptance criteria

- Offline test with stubbed aws: missing snapshot → non-zero exit naming it; residue under `none` → non-zero exit listing it.
- Report text is derived from observed evidence (snapshot id from the provider response).
- Demo/example: not applicable — state in completion notes.

## Completion notes (2026-09-24, landed as HARDEN-004 step 5)

**Premise re-verified** against `origin/main @ 71d3ee79` before starting: `retention_report`
was still called from the destroy edge and still rendered the policy, and
`grep -rn 'describe-db-snapshots' cli/sol/bin/` still returned nothing. The premise held.

**What landed.** `Sol_cli_cloud_lifecycle.retention_report` is deleted; retention is reported
from a typed observation (`Sol_cli_destroy_verification`). AWS `final-snapshot` queries
`aws rds describe-db-snapshots --db-snapshot-identifier <the id the preparation established>`
and requires the provider to report it `available`; AWS `none` queries
`--db-instance-identifier <the captured instance>` and requires no manual or automated
snapshot for it; GCP has no snapshot surface and the report says so instead of claiming "no
residual billable artifacts". A provider answer about a different identifier is not evidence
about this one.

**Acceptance criteria, as observed:**

- missing snapshot → non-zero exit naming it: `test_destroy_verification.ml` pins
  `DBSnapshotNotFound` → `Retention_violated` naming the identifier, and the offline harness
  scenario `RDS_SNAPSHOT_MISSING=1` asserts the destroy fails with
  `final-snapshot NOT observed` and `the target declared it keeps its final snapshot`.
- residue under `none` → non-zero exit listing it: the harness scenario
  `RDS_SNAPSHOT_RESIDUE=1` asserts failure with `leaked-manual` named and
  `retain-nothing NOT observed` in the message.
- report text derived from observed evidence: the harness asserts the report contains
  `final snapshot <id> observed available` for the identifier the *preparation* established,
  and that the old policy-only wording ("no residual billable artifacts") is **absent** from
  the output.

Also covered beyond the criteria: a snapshot still being created is observed for a bounded
time and then reported UNKNOWN (a failure, never a met guarantee), and a snapshot that is
`creating` once and then `available` is *observed* — so a retry that did not happen fails.
An unobservable query (timeout, permission, unavailable CLI) is UNKNOWN and fails.

**Dependency note.** `Depends on: REFAC-091` is satisfied in substance for this ticket: the
destroy half (`Sol_cli_cloud_destroy.execute ~deps`, Step 2) is merged. REFAC-091's *install*
half remains open, which is why that ticket is still in `READY_FOR_ENGINEERING` — but nothing
INFRA-072 needed from it is outstanding.

**Demo/example: not applicable** — this changes what a destroy *reports and refuses*, not what
an application author writes; no `sol.toml` field, generated manifest or runtime contract
changed. **No language-parity impact** (DEC-022): nothing application-facing changed.
