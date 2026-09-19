# FND-0006 — Retention: a disposable target reaches provider-side `Absent` retaining nothing

- **Classification:** `QUALIFICATION_GAP`
- **State:** `QUALIFIED` (HARDEN Run 7 attempt 7 — `main @ 7ea2ef43`, target
  `sol-qual11-116c2637`, `destroy_retention: none`)
- **First identified:** 2026-09-19 (HARDEN Run 6 / Attempt 6)
- **Last verified:** 2026-09-19, `main @ 910a59f1` (reconciled after Run 7)
- **Provider:** AWS (GCP retention is inexpressible — see below)
- **Derived ticket:** **INFRA-041** (DONE)
- **Related invariant:** `INV-RET-1`, `INV-RET-2`
- **Related decisions:** DEC-033, ADR 0004
- **Evidence:** `internal/pipeline/tickets/DONE/INFRA-041.md`; HARDEN-002
  Attempt 6 (the defect) and Attempt 7 (the live postcondition)

## Sol claim at stake

DEC-033: "A disposable qualification target can be destroyed to zero residual
billable artifacts without any manual step", and "`sol cloud destroy` reports the
artifacts it deliberately retained, by identifier".

## What was defective (fixed)

Run 6's target declared `destroy_retention: none`; the destroy took a final
snapshot anyway and printed no retention line, so cost-clean again required a
manual `delete-db-snapshot`. INFRA-041 found two defects: `retention_report` was
never called, and the target's `none` value did not reach the resolve point.
Both were fixed, and the harness asserts **both** modes:

- `none` prepares without an expected snapshot identity, and the post-prepare
  verification reads `skip_final_snapshot` (an empty identifier alone cannot
  distinguish "keeps nothing" from "keeps the default");
- `final-snapshot` still fails closed when the provider's record disagrees.

## Evidence available

| Tier | Evidence |
|---|---|
| STATIC | the two-mode fix and tests; `policy_vars` + `retention_report` invoked |
| MECHANISM | the offline lifecycle harness asserts both modes, driven by the selected policy rather than one expected value |
| BEHAVIORAL | **Run 7 attempt 7**: the destroy reported its selection before acting, verified preparation against the selected policy, and ended with `retention: none (target destroy_retention = none) -- destroyed to Absent with no residual billable artifacts`; independent verification found **zero manual snapshots**, EKS none, RDS 0, EC2 terminated, NAT deleted, EIP/LB/EBS/VPC/ECR none |

The Run 7 verbatim output:

```text
prepare: disabling RDS deletion protection, retaining nothing...
verify preparation: RDS deletion protection disabled, final snapshot skipped
  (skip_final_snapshot=true) (target destroy_retention = none)
retention: none (target destroy_retention = none) -- destroyed to Absent with no
  residual billable artifacts
```

## What is established

Both live halves of DEC-033's contract, on a fresh disposable target, with no
manual step: the destroy states what it retained, and a `none` target ends with
no residual billable artifact. Attempt 6 could reach the same end state only
through an operator deviation; Attempt 7 did not need one.

## What is NOT established

Nothing outstanding for the `none` mode. The `final-snapshot` default's live
retention row remains a production behaviour, not a qualification target, and is
unchanged.

## GCP note

GCP cannot express retention: Cloud SQL deletes backups with the instance. A GCP
target using the `final-snapshot` default is **refused** rather than destroyed
(`gcp-bootstrap-inventory.md`, reconciliation table). This is correct, explicit
behaviour — recorded here so the asymmetry is not mistaken for a gap.

## To move further

Not applicable — the row is qualified. A future run that changes the retention
mechanism (e.g. a new provider or a new retained-artifact kind) re-opens it by
the DEC-026 §9 rule (a claim is per target, profile version and timestamp).

## Supersession

HARDEN-002's Attempt 6 "cost-clean" claim, which required a manual snapshot
deletion, is `SUPERSEDED` as qualification evidence by Attempt 7.
