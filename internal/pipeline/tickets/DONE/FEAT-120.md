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

## Completion notes (2026-10-01)

### The run

Record: [`internal/qualification/records/2026-10-01-outbox-failure-qualification.md`](../../../qualification/records/2026-10-01-outbox-failure-qualification.md),
at `main @ 44e3061b`. It is the run-local path — `examples/pluto`'s own
`notify_worker/bin/main.exe` against a dedicated database and an **isolated** Redpanda container
(`sol-qual-redpanda`), so the outage scenario never touched the shared broker.

### Acceptance mapping

| Required evidence | Result |
|---|---|
| Rollback — no domain row, no job, no outbox record, no fact | **PASS** (S2): a seeded conflicting outbox row made the transaction's insert fail; `notifications=0`, `jobs=0`, only the seeded outbox row, no fact |
| Worker `Fail` — offset uncommitted, consumer stops, failure telemetry | **PASS** (S3): `sol_worker_messages_total{status=fail}`, "the offset is not committed and the consumer stops", `handler returned without calling ack()` |
| Duplicate delivery / dedupe | **PASS with a finding** (S1): the independent effect did not run twice, but the domain insert duplicated the notification row → **BUG-112** |
| Kafka unavailable after commit, then recovery | **PASS** (S4): the row was held while the broker was down (`outbox=1`), then published and removed on recovery, the fact present — no loss |
| Same-key ordering | **PASS** (S5): `ord=2` inserted before `ord=1`, published `seq1` then `seq2` |
| Relay restart / recovery | **PASS** (S6): restarted between scenarios and resumed without a gap |
| Crash between broker ack and the database mark | **NOT REACHED** (S7): no hook to kill the relay in that window; the package test asserts it, the run did not observe it |
| Job retry in `sol-jobs`, not a Kafka retry topic | **NOT REACHED** (S8): the demo's job handler cannot fail; the isolated broker's topics show no retry topic, only the framework's decode-error DLQ |

### What the run does not establish

It is not the deployed `sol up` path, and it does not observe the crash-boundary duplicate or
job retry/backoff. The `Charged` events were produced out of band because the example's
`charge_svc` accepts through Postgres by design; a live `sol up` run and a failure-injectable
job would close those two.

**Demo/example coverage:** the run *is* the example; the duplicate-delivery gap it found is
filed as BUG-112.

**TypeScript parity (DEC-022):** unchanged — the TypeScript outbox does not exist (FEAT-119's
family records that gap); BUG-112 carries the duplicate-delivery question to the TypeScript
consumer.

