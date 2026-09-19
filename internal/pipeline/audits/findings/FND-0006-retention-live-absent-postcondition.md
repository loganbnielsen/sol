# FND-0006 — Retention: code and harness are correct, the live `Absent` postcondition is not yet demonstrated

- **Classification:** `QUALIFICATION_GAP`
- **State:** `FIXED_UNQUALIFIED` (INFRA-041 fixed the code/harness; the live `none → Absent` behaviour is not observed)
- **First identified:** 2026-09-19 (HARDEN Run 6 / Attempt 6)
- **Last verified:** 2026-09-19, `main @ 7ea2ef43` (INFRA-041 merged)
- **Provider:** AWS (GCP retention is inexpressible — see below)
- **Derived ticket:** **INFRA-041** (DONE)
- **Related invariant:** `INV-RET-1`, `INV-RET-2`
- **Related decisions:** DEC-033, ADR 0004
- **Evidence:** `internal/pipeline/tickets/DONE/INFRA-041.md`; HARDEN-002 Run 6

## Sol claim at stake

DEC-033: "A disposable qualification target can be destroyed to zero residual
billable artifacts without any manual step", and "`sol cloud destroy` reports the
artifacts it deliberately retained, by identifier".

## What was defective (fixed)

Run 6's target declared `destroy_retention: none`; the destroy took a final
snapshot anyway and printed no retention line, so cost-clean again required a
manual `delete-db-snapshot`. INFRA-041 found two defects: `retention_report` was
never called, and the target's `none` value did not reach the resolve point.
Both were fixed, and the harness now asserts **both** modes:
- `none` prepares without an expected snapshot identity, and the post-prepare
  verification reads `skip_final_snapshot` (an empty identifier alone cannot
  distinguish "keeps nothing" from "keeps the default");
- `final-snapshot` still fails closed when the provider's record disagrees.

## Evidence available

| Tier | Evidence |
|---|---|
| STATIC | the two-mode fix and tests; `policy_vars` + `retention_report` invoked |
| MECHANISM | the offline lifecycle harness asserts both modes, driven by the selected policy rather than one expected value |
| BEHAVIORAL | **not yet.** No run has reached `Absent` under `destroy_retention: none` without a manual snapshot deletion |

## What is established

The selected policy reaches the provider correctly in both modes, and the report
is wired. This is genuine mechanism evidence and is not downgraded.

## What is NOT established

The live postcondition: a disposable target's destroy ending with zero residual
billable artifacts, no manual step, and a retention report that says so. The
most recent live data point is Run 6, where the operator deleted the snapshot by
hand (deviation 4).

## Impact

"Destroyed and cost-clean" remains an operator-attested property for the
`none` mode until a run demonstrates it end to end. The code no longer *causes*
the deviation, but the qualification row is still open.

## GCP note

GCP cannot express retention: Cloud SQL deletes backups with the instance. A GCP
target using the `final-snapshot` default is **refused** rather than destroyed
(`gcp-bootstrap-inventory.md`, reconciliation table). This is correct, explicit
behaviour — recorded here so the asymmetry is not mistaken for a gap.

## To move to qualified

A disposable AWS target declaring `destroy_retention: none` reaching `Absent`,
with the destroy output naming nothing retained and no manual snapshot deletion,
and an independent provider-API absence check.

## Supersession

HARDEN-002's earlier "cost-clean" claims that required a manual snapshot
deletion are `SUPERSEDED` as qualification evidence by this finding's open row.
