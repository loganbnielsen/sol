---
id: FEAT-094
type: feature
severity: low
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

Detect edits to already-applied migrations (checksum validation)

**Depends on:** None.

**Finding:** FND-0032 (`internal/pipeline/audits/findings/`).

**Premise verified 2026-09-23** against `origin/main @ f3e9480b` while filing (see the finding).

## Problem

Neither pg-eio nor Sol's gate records a content checksum; editing an applied migration file is silently ignored.

## Remediation

Store a checksum per applied migration and have `status`/the deploy gate report a mismatch.

## Acceptance criteria

- A modified applied migration is reported by `sol migrate status` and fails the production gate.

## Decision (2026-10-03) — fail the deploy gate

Question: should a checksum mismatch fail the deploy gate, or only warn? (Flyway
fails; some teams allow repeatable edits.) Consequence of failing closed: it can
block a legitimate repeatable edit. Consequence of warning: a silent divergence
stays silent. Surfaced to the operator as a category-5 decision; not deferred.

Operator decision: **Fail the deploy gate.** Store a checksum per applied
migration; `sol migrate status` reports a mismatch and the production gate fails
on an edited already-applied migration. Promoted to
`READY_FOR_ENGINEERING`.

Recorded in `internal/pipeline/audits/2026-10-03_backlog_adjudication.md`.

## Completion notes (2026-10-03)

**Premise verified.** Neither pg-eio's `Migration` nor Sol's gate recorded a
content checksum; `Migration.status` returned `(version, name, applied_at)` and
`Sol_cli_migration` compared versions only, so editing an applied file was
silently ignored by the runner and the gate alike.

**Implementation spans the two owners.** The tracking table is pg-eio's
(`Migration` creates it and writes the rows), so the checksum is recorded there:
pg-eio PR [#27](https://github.com/loganbnielsen/pg-eio/pull/27), merged as
`0c47f91`, `support-refs.txt` and the five `*.opam` pins bumped to it in this
branch. pg-eio now stores `checksum` on the row, returns `checksum` and
`content_checksum` from `status`, and refuses `apply` while an applied file
disagrees with its record. Sol adds the policy:

- `sol migrate status` gains a `DRIFT` column, prints each drifted migration
  with both checksums, and exits non-zero; `--json` carries
  `recorded_checksum`/`content_checksum` per migration and deliberately exits
  zero, so the reporting Job still succeeds and the gate — not the Job's status
  — owns the refusal and can name the drifted migration.
- The deploy gate parses those fields into `Sol_cli_migration.applied_status`
  (`applied` + `drifted`) and checks drift **before** the required-set
  comparison: a drift is reported as `Drifted` and the deploy fails before any
  workload moves, naming each migration and both checksums, with the remedy
  (restore the file, or put the change in a new migration).
- A version applied before checksums existed has `recorded_checksum: null` and
  is reported as uncomparable, never as drift — an absent record is not evidence.

**Docs/examples.** `docs/deployment/migration-ordering.md` states the contract
and the `Drifted` gate outcome; the tutorial's `migrate status` sample output
gains the column and a paragraph on the remedy; `docs/reference/cli.md` is
regenerated from the command's own help (the `status` doc string changed, so the
page was rendered, not hand-edited). An `examples/` change was not applicable:
no app-author surface (field, command, generated manifest) changed — the
migration files and commands are the same, and only the diagnosis and refusal of
an edited applied file are new.

**Evidence.** pg-eio's suite runs against a live PostgreSQL 16: 32 tests, with
three new integration tests (checksums recorded and reported; an edited applied
file refused; an unrecorded baseline not compared). Sol's inline tests cover the
JSON round-trip, the drift parse, and the gate/test updates. End-to-end against
the local PostgreSQL with the built CLI: clean apply and status exit 0 and show
`DRIFT -`; after editing the applied file, `status` shows `DRIFT yes`, names both
checksums, and exits 1, `status --json` exits 0 carrying both checksums (the
runner reports; the gate refuses), and `apply` is refused with both checksums.

**Boundary recorded, not absorbed.** `sol rollback` reads applied *versions*
from the same Job and ignores drift, so a drifted applied migration does not
block a rollback today. The rollback boundary is DEC-018's expand/contract
question, not this ticket's; named here so the omission is explicit.

**Live verification remaining.** The deploy gate's in-cluster Job path is
covered offline (comparison + encoding) and by the runner changes above, but the
`production-single-region` deploy that observes `Drifted` end to end runs with
the qualification campaign (HARDEN-007); no local target selects that profile.

**TypeScript parity:** no impact — migrations are app-language neutral.
