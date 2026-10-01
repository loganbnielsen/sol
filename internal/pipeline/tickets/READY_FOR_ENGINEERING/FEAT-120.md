---
id: FEAT-120
type: verification
severity: high
title: Qualify the outbox path end to end under failure, not just the happy path
source: "FEAT-111 (transactional outbox); the standing qualification ledger's live-run rule"
---

**Depends on:** FEAT-121.

**Authorized (2026-10-01):** the operator's Stream B handoff authorizes this live run, so the
ticket leaves `BACKLOG` and is promoted to `READY_FOR_ENGINEERING`. The path it qualifies is on
`main`: the outbox (`FEAT-111`) and the pluto demo wiring (`FEAT-121`).

**Premise verified (2026-10-01):** the outbox exists (`framework/ocaml/sol-outbox`, FEAT-111)
and the demo publishes through it (FEAT-121); the run's record lands under
`internal/qualification/records/`.

**Related:** FEAT-111 (the outbox under qualification), EXP-033 (the transaction-scoped
handle the outbox publishes through), FEAT-112 (idempotent enqueue), DEC-021's 2026-09-29
amendment, `internal/qualification/README.md` (the live-run rules: strict evidence, no
in-run remediation).

## What to qualify

The recommended composition, through the normal local/golden path — not a bespoke
harness that re-implements it:

```
domain transaction + outbox  →  Kafka fact  →  sol-worker  →  sol-jobs  →  retryable effect
```

Run it against `sol local infra up` + `sol up` on a workspace that declares the shape
(pluto, or a workspace scaffolded for it), with the checks below. A live run is its own
record (`internal/qualification/records/`), and this ticket names the run it produces.

## Required evidence — failures first

The happy path is the least interesting case. Each of these is a separate recorded
observation, with the command and its verbatim output:

1. **Rollback.** A handler whose transaction rolls back after enqueueing: no Kafka fact,
   no job row, no domain row. Assert all three, not just the domain row.
2. **Kafka outage then recovery.** Stop the broker (or block the topic), commit a fact,
   observe the relay hold rather than lose or reorder it, restore the broker, and observe
   the fact arrive and the job run exactly once *from the consumer's point of view*.
3. **Duplicate delivery / dedupe.** Deliver the same fact twice (broker redelivery, or a
   re-publish of the same event id). The consumer must be idempotent at the application
   level and the dedupe key must produce one job, not two.
4. **Worker `Fail`.** A handler that returns `Fail`: the offset stays uncommitted, the
   consumer stops, and the outbox/journal state is unchanged rather than partially
   applied.
5. **Job retry.** A job whose handler fails transiently: it is retried with backoff,
   succeeds, and is not duplicated; a job that exhausts `max_attempts` reaches `'failed'`
   with `last_error` set.
6. **Same-key ordering.** Many records for one key, committed in order, under a relay
   restart mid-stream: the consumer observes them in commit order, and the relay never
   advances that key past an earlier unpublished event. This is the property the outbox
   exists for; a run that only shows "all records arrived" does not qualify it.
7. **Crash between broker ack and the database mark.** Kill the relay after a publish
   succeeds and before the mark commits. The observed outcome must be *duplicate, never
   gap or inversion* — record which of the two the run produced, and that the consumer's
   idempotency absorbed it.

## Non-goals

- Not implementing the outbox (FEAT-111) and not fixing anything found here: a live
  qualification run records what it observed, and a defect becomes its own finding.
- Not a unit or integration test suite; those live with the code.

## Acceptance criteria

- Every item above has a recorded observation naming the command and its output, or an
  explicit note that the run did not exercise it and why.
- The ordering and rollback observations are the primary evidence, not the happy path.
- The run's record is linked from this ticket and from
  `internal/pipeline/audits/QUALIFICATION_STATUS.md`.

**Demo/example coverage:** the run *is* the example — it uses the scaffolded workspace and
the generated contract, so a gap between the documented path and the real one shows up as
a failed run.

**TypeScript parity:** out of scope for this run; the TypeScript outbox does not exist
(FEAT-119's family records that gap).
