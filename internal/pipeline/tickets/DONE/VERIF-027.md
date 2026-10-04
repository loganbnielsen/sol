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

## Attempt 1 (2026-10-04) — blocked by a host service; not runnable yet

Premise re-checked at `origin/main @ 5e5eba74`: the run own remaining dependency was the
TypeScript namespace driver. It now exists (`internal/qualification/local/rows-ts.sh`,
with its offline mutation-checked suite), and both drivers deploy step is fixed
(`sol up local` -> `sol up`, which the CLI refuses).

The run reached a fresh `sol-local` cluster and `sol local migrate` -> `Done.`, then
stopped at `sol up`: the contract registration goes to `http://localhost:8081`, which on
this host is the native dev Redpanda rather than the harness IPv6-loopback port-forward,
so every deployed unit crash-looped verifying against an empty in-cluster registry. No
row is promoted; the mechanism, the verbatim output and the row-by-row verdicts are in
`internal/qualification/records/2026-10-04-local-alpha-1.md`.

**Blocked on an operator action:** stop the native Redpanda on this host (user
`redpanda`, pid 370; `kill` from this session returned `Operation not permitted`, and
`sudo` needs a password), or grant it, so the run forwards own `9092`/`8081`/`9644`. Then:
`local-qual.sh preflight` -> `infra` -> `sol local secret set POSTGRES_URL`/`SOL_API_KEY`
-> `sol local migrate` -> `ROWS_SH=.../rows-ocaml.sh ... rows` -> `rows-ts.sh` ->
`capture` -> `teardown`.

Filed from the attempt: `INFRA-102` (`sol up` registers against a literal address and
reports success against whatever answers there).

## Completion (2026-10-04) — the local rows qualify at `47fc2266`

The campaign's local run completed at `origin/main @ 47fc2266` with the staged
`v0.1.0-alpha.7` bundle. Scenario rows `B1`, `B2`, `B5`, `B6`, `D5`/`H1` and `H2` are
`PASS (LOCAL)` in **both** the OCaml and TypeScript namespaces; capability rows `C1`,
`D1`–`D4`, `D6`, `G1`, `G2`, `G6` and `G7` are `PASS (LOCAL)`; teardown reached verified
absence (`cluster ABSENT`, `containers ABSENT`). The record is
`internal/qualification/records/2026-10-04-local-alpha-1.md`; the bundle is
`/tmp/alpha-verif027-47fc2266/`; `internal/qualification/ALPHA_CAMPAIGN.md` and
`internal/pipeline/audits/QUALIFICATION_STATUS.md` carry the row changes.

Defects the campaign exposed, fixed, mutation-tested and merged: `INFRA-102`
(`449d933c`), `BUG-200` (`9c59d4be`), `BUG-201` (`478bd72c`), `BUG-202` (`47fc2266`). The
run's own drivers were corrected in `VERIF-027` parts C–E (#1062, #1064, #1065).

Not established here, left at their prior verdicts: `C3`, `F8`, `F9`, `G3`–`G5`, `G8`,
`G9`, `H7` (not observed by this run); the provider rows (need a real target); `A1` and
`J*` (need the published release). No verdict was weakened. Recorded deviations: the
cluster was reused rather than recreated (Helm could not fetch a chart to re-reconcile
infra on this host), and the bundle's migration-runner digest is synthetic pending the
release tag.

**Rerun after `BUG-203` (`bddd58e3`).** The post-merge `test` failure on `main` for
`d0cff2f6` was a real `sol-jobs` lease defect, not a flake: a heartbeat that woke after the
lease lapsed surrendered a live, unclaimed claim, and a second poller ran the handler.
`BUG-203` fixed it, and the rows that exercise `sol-jobs` were re-observed at
`bddd58e3` on a freshly provisioned cluster: `B1`, `B2`, `B5`, `B6`, `D5`/`H1` and `H2`
pass in both namespaces, and teardown again reached verified absence. `47fc2266` and
`bddd58e3` differ only by `BUG-203`'s renewal fence.
