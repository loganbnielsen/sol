---
id: HARDEN-007
type: verification
severity: high
title: AWS qualification run 9 — the deploy scenarios from B3 onward
source: internal/qualification/README.md (the run that replaces the HARDEN-002 epic's frontier)
---

**Depends on:** INFRA-060, INFRA-062, INFRA-076.

**Related:** HARDEN-002 (closed epic), FND-0020, FND-0022, INFRA-051, FND-0021.

## Blocked On

Explicit operator authorization for a live, billable AWS run. Promote to
`READY_FOR_ENGINEERING` only when it is given.

## Goal

Run 8 stopped with §B3 `NOT REACHED`, for two documented reasons: no qualification-only transport
to private application services (FND-0020 / INFRA-060) and no defined way to re-establish a workload
fixture (FND-0022 / INFRA-062). With both resolved, qualify §B3–§B7 and the consumer-dependent
§D/§E rows of `internal/qualification/aws/production-single-region-v1-matrix.md`. Also re-check whether
`sol deploy` can write `sol-deploy-state-<workspace>` (the Run 8 post-boundary observation that
shares INFRA-051's root cause).

## Acceptance criteria

- Run under the operating rules in `internal/qualification/README.md` and the procedure in
  `internal/qualification/aws/aws-run-procedure.md`.
- `terraform state pull` captured into the evidence bundle before any teardown.
- A run record `internal/qualification/<date>-aws-run9.md` from `run-record-template.md`, with each
  targeted matrix row qualified, blocked or not reached.
- Teardown to `Absent`, verified independently of Sol's report.
- `internal/pipeline/audits/QUALIFICATION_STATUS.md` updated.
