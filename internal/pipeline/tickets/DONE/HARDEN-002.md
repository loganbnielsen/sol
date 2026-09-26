---
id: HARDEN-002
type: verification
severity: high
title: Build and run production-single-region conformance
source: production platform contract review 2026-09-16
---

**Closed as a ticket on 2026-09-24 — converted to the qualification ledger.** This was a
standing verification epic ("qualify the production-single-region profile"), not a unit of
work that can finish, so it sat in `READY_FOR_ENGINEERING/` indefinitely and read as
actionable to `/work`. Its goal and acceptance criteria are kept below as written. Its run
history (Runs 1–7, previously appended to this file) moved verbatim into per-run records in
`internal/qualification/` (index below); where the profile stands lives in
`internal/pipeline/audits/QUALIFICATION_STATUS.md` and the matrix
`internal/qualification/aws/production-single-region-v1-matrix.md`. The next live AWS run is its own
ticket (HARDEN-007). References elsewhere of the form "HARDEN-002 run N, finding M" resolve
through the index.

**Depends on:** FEAT-089, FEAT-050, AUDIT-080, AUDIT-069, AUDIT-072, AUDIT-078, SEC-004, OBS-043, FEAT-088.

**See also:** HARDEN-004 — the same contract realized and qualified on GCP. It is a
separate workstream (different mechanisms, same guarantees), and its per-attempt
evidence lives in `internal/qualification/gcp/gcp-bootstrap-inventory.md`. Changes to the
shared platform definition or to provider-neutral lifecycle semantics have to keep
both tickets' contracts, so a change here that looks AWS-local is worth checking
against that ticket.

## Goal

Turn the guarantees of the versioned `production-single-region` profile into one
executable qualification run and a reviewable evidence bundle. This is the
conformance epic; it does not invent guarantees or reimplement their mechanisms.

## Minimal harness

Use the existing deployment plan, release/deployment records, CLI status and
golden-path infrastructure. Add only the orchestration needed to create an
isolated qualification target, run scenarios, collect evidence and tear it down
safely. Do not build a generic certification service.

The evidence bundle records:

- profile and supported component versions;
- resolved target identity and selected reconciliation authority;
- workload artifact digests;
- scenario start/end, outcome and relevant diagnostics;
- restore point/result and measured recovery/data-loss observations;
- alert-delivery acknowledgement; and
- explicit skipped capabilities that the workload does not use.

## Required scenarios

1. Fresh provision and normal deployment.
2. Deliberately failed deployment.
3. Rollback to the prior compatible release.
4. Node drain and unplanned node loss for workloads claiming tolerance.
5. Postgres loss and Kafka/broker loss for capabilities in use.
6. Database/application-data restore into a clean target.
7. Runtime credential rotation and old-credential revocation.
8. Synthetic alert delivery and acknowledgement.
9. Drift detection or correction according to DEC-027.
10. One representative application transaction after each recovery.
11. Lifecycle phase, authority and desired-state policy (ADR 0003; matrix section
    I): privileged installation authority present only during the install, revoked
    after verified `Ready`; `Ready` policy in force only in `Ready`;
    `PlatformUpdating` re-entry and return to `Ready`; destroy under the Destroy
    policy; and public destruction of a failed or partially installed target.
12. Abort/resume of the destroy lifecycle (matrix rows I10–I12): a target whose
    platform install did not complete is still destructible through Sol, and an
    interrupted destroy can be resumed.

Scenarios 11 and 12 were added for Run 5: they are the lifecycle contract the
model now defines, and they are the only scenarios whose *state* is deliberately
not a healthy one.

## Acceptance criteria

- One command or documented CI job runs the complete required qualification for
  the selected profile without manual result editing.
- A failed required scenario returns non-zero and marks the evidence bundle
  non-conformant.
- Evidence distinguishes implementation/config inspection from live behavioral
  proof; static YAML assertions cannot pass a failure scenario.
- The run is repeatable on a clean target using only the declared compatibility
  matrix and named credentials.
- Secrets are redacted and teardown is independently verified.
- The resulting evidence is sufficient for PROD-001's launch review.
- The lifecycle contract (matrix section I, ADR 0003) is qualified in the same
  run: the phase reported at each step is paired with an independent observation
  of the authority and policy actually in force, and a failed/partially installed
  target is shown to remain destructible through Sol's own public lifecycle —
  with no out-of-band resource deletion anywhere in the run.
- Every live assertion names the artifact it must retain, so a reader can check
  the claim without re-running anything (matrix rows I1–I13 and the run-identity
  lifecycle-phase record).

**Demo/example coverage:** Run against the same readable production-profile
example used for the pilot, not a hidden test-only workload.

**TypeScript parity:** Run the language set selected by DEC-026. If both are in
scope, both must execute representative deployed behavior; shared substrate
failure scenarios need not be duplicated without value.

## Where the run history went (moved verbatim, 2026-09-24)

| Section (original heading) | Record |
|---|---|
| Progress — run 1 (BLOCKED), Remediation, run-1 evidence review, run-2 delta | `internal/qualification/records/2026-09-17-aws-run1.md` |
| Run 2 — five production-path defects (findings 4–8) | `internal/qualification/records/2026-09-17-aws-run2.md` |
| Run 3 and Run 4 | `internal/qualification/records/2026-09-18-aws-run3-run4.md` |
| Run 5 attempt 1 (finding 16) | `internal/qualification/records/2026-09-18-aws-run5-attempt1.md` |
| Run 5 attempt 2 (finding 19) | `internal/qualification/records/2026-09-19-aws-run5-attempt2.md` |
| Run 5 attempt 3 (finding 20) | `internal/qualification/records/2026-09-19-aws-run5-attempt3.md` |
| Run 5 attempt 5 — conformant through Ready | `internal/qualification/records/2026-09-19-aws-run5-attempt5.md` |
| Run 7 attempt 7 — first migration through a cloud target | `internal/qualification/records/2026-09-19-aws-run7-attempt7.md` |
| Run 6 attempt 6 — application-centric | `internal/qualification/records/2026-09-19-aws-run6-attempt6.md` |
| Run 5 procedure (preconditions, command sequence, evidence identity, harness discipline) | `internal/qualification/aws/aws-run-procedure.md` |
| Run 8 (already its own record) | `internal/qualification/records/2026-09-20-run8-aws.md` |
