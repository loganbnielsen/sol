---
id: VERIF-027
type: verification
severity: high
title: "Local integrated qualification: the alpha acceptance matrix on a fresh k3d cluster with the released bundle"
source: internal/qualification/ALPHA_CAMPAIGN.md — the local rows of the acceptance matrix, observed end to end
---

**Depends on:** RELEASE-006, FEAT-132, FEAT-133, VERIF-028.

**Related:** FEAT-131, `internal/qualification/local/local-run-procedure.md`, `internal/qualification/observability/`, `internal/qualification/aws/`, `internal/qualification/gcp/`.

Observe the alpha acceptance matrix's local/cluster rows against the reference
application on a fresh cluster, with the released bundle rather than a development
build — the closest practical clean-user environment before the cloud runs. This is
the run that turns the `NOT RUN` local rows into honest verdicts and that produces the
records the AWS/GCP runs build on. It needs no cloud account and no operator
authorization.

## What it must observe

Every row in `internal/qualification/ALPHA_CAMPAIGN.md` §3 whose target includes
`local`, at the evidence class the row needs, using `internal/qualification/records/`
`run-record-template.md`:

1. **Scenario happy path (B1-B5).** One `POST /orders` through both the OCaml and the
   TS namespace: the domain row, the job, the outbox intent, the published facts, the
   worker's own transaction, the job effects and the read-back.
2. **Atomicity and duplicate delivery (B2, B6).** Kill the process between the domain
   write and the publish; deliver the same fact twice; assert one fact yields one row,
   one job, one intent, one effect.
3. **Migrations and jobs (C1-C3, C5-C6).** `sol migrate apply`, the deploy gate's
   `required ⊆ applied` failure, a checksum mismatch, job lease/retry, and the outbox
   relay's ordering under a blocked head.
4. **Kafka contract and DLQ (D1-D6).** Declared partitions and key, registration
   fatality, retry/DLQ topology, and an undecodable record producing the decode log,
   the decode metric and the DLQ record.
5. **Observability (G1-G9).** The six identity dimensions on logs, metrics and traces;
   one request's three signals agreeing; `sol logs`/`sol status`/`sol open`/
   `sol check`; dashboard proxy queries; the alert delivery route to a local receiver.
6. **Failure and recovery (H1-H2, H7).** Broker unavailable then recovered, relay
   restart, telemetry loss degradation, and a deploy -> failure -> diagnose ->
   rollback -> recover loop against the local cluster.
7. **Teardown.** `sol local infra down` leaves no cluster and no residual state; the
   workspace can be redeployed from clean.

Capture the environment honestly in the record: the released bundle version, the
revision, the chart versions, the fact that no cloud account was involved, and any row
that a local cluster cannot establish (it stays `NOT RUN` or `BLOCKED` with the reason,
never weakened).

## Acceptance criteria

- A run record exists in `internal/qualification/records/` from the template, with each
  targeted row's verdict and the verbatim command and output for each observation.
- Failure-injection rows record the mechanism and its observable effect, not just a
  green path.
- Any concrete Sol defect the run exposes is filed, fixed if bounded, mutation-tested
  and merged, and the affected row rerun within the same campaign.
- `internal/pipeline/audits/QUALIFICATION_STATUS.md` and the observability matrix
  (`internal/qualification/observability/observability-diagnostic-matrix.md`) are
  updated with the run identity and the rows it moved.
- Demo/example: the run uses the workspace's own documented commands; any gap between
  the README and the real commands is fixed here.

## Completion notes

Leave each row's before/after verdict, the run record path, and the list of defects the
run exposed and their tickets.
