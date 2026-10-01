---
id: VERIF-001
type: verification
severity: high
title: Prove the transactional facts-to-jobs architecture through the local golden path
source: retry/outbox golden-path coverage discussion (2026-09-30)
---

**Depends on:** FEAT-111, BUG-105.

**Related:** `BUG-099` (Kafka key and partition contract), `FEAT-112` (idempotent
jobs enqueue), `FEAT-113` (Kafka Ack/Fail semantics), `EXP-033` (transaction-scope
investigation). The first three are already in `DONE/`; the investigation does
not gate this verification.

**Premise verified (2026-09-30):** `FEAT-111` requires outbox component tests and
a Pluto example, while `.github/workflows/ci.yml` has a local golden-path smoke;
no ticket requires that smoke to exercise the complete outbox → Kafka → worker →
jobs flow and its failure boundaries.

## Goal

Use the normal local golden path and a representative Pluto application flow to
prove: domain state and outbox intent commit in one Postgres transaction; the
relay publishes an ordered Kafka fact; a worker acknowledges the fact after
idempotently enqueueing an independent effect; `sol-jobs` executes and retries
that effect. Extend the existing fixture and smoke rather than creating a
second demo architecture. Exercise public application contracts where practical.

## Acceptance criteria

- The local golden-path smoke runs the full flow, checks the declared topic,
  key and partition, observes worker consumption and successful job execution,
  and checks the relevant Sol logs and metrics.
- A forced transaction rollback leaves no domain change, durable outbox event,
  Kafka fact or downstream job.
- With Kafka unavailable after commit, domain state and the unpublished outbox
  row remain durable. On recovery, publication succeeds and the row is marked
  published only after broker acknowledgement. Exercise the publish/mark crash
  boundary and verify its documented at-least-once behavior.
- Duplicate fact delivery uses the stable event ID as the jobs dedupe key and
  does not execute the independent effect twice.
- A worker handler returning `Fail` does not commit the Kafka offset; the
  consumer stops and emits operator-visible failure telemetry. No application
  retry topic or application dead-letter route handles the fact.
- A transient job failure retries in `sol-jobs` and eventually succeeds without
  replaying the already acknowledged Kafka fact.
- Multiple facts for one domain key stay on one partition. A blocked earlier
  outbox event prevents later events for that key from publishing first;
  induced duplicate publication does not invert their order.
- The runnable example and golden-path documentation show the supported split:
  Postgres plus outbox records atomic publication intent, Kafka distributes
  ordered facts, the worker uses Ack/Fail, jobs retry independent effects, and
  consumers handle at-least-once delivery idempotently.

Record the smoke command and observed results in the completion notes. Framework
unit tests alone do not satisfy this ticket. Record the TypeScript parity verdict
for the application flow in those notes; if deferred, name its tracking ticket
and trigger.

## Completion notes (2026-10-01)

**Premise re-verified (2026-10-01):** `.github/workflows/ci.yml`'s `golden-path-smoke`
deploys a *scaffolded* workspace whose `notify_worker` inserts a notification and returns
`Ack`/`Fail` — it never publishes through the outbox or enqueues a job, and the only wired
composition in the tree is `examples/pluto/app/comms/notify_worker` (FEAT-121). No smoke
exercised the outbox → Kafka → worker → jobs flow. The `sol-outbox` package (FEAT-111) and
the `sol_outbox` table are both on `main`.

### What landed

`internal/fixtures/local-demo` — the existing e2e golden-workflow fixture, not a second demo
architecture — gains a second path, `run_outbox_path` in `test/test_e2e.ml`, which runs the
recommended composition through the **public application contracts** against real
infrastructure:

```
domain transaction + outbox  →  Kafka fact  →  sol-worker  →  sol-jobs  →  retryable effect
```

It uses `Kafka_service.register`/`publish`, `Sol_outbox.Make(…).publish`/`relay`,
`Worker.For_testing.Make`, and `Sol_jobs.Make(…).enqueue`/`run` — what an app author writes,
not a bespoke harness. `internal/fixtures/local-demo/migrations/0004_outbox_e2e.sql` documents
the same tables for the fixture's demo binary, and the test creates its own schema explicitly
and truncates per run so it is robust to the framework suites that drop and recreate
`sol_jobs`/`sol_outbox` in the same database.

The CI `test` job runs it as its own gated step, *Facts-to-jobs golden-path smoke (broker and
database backed)*, after the framework integration step so it reuses the same broker and
Postgres.

### Evidence

Smoke command (the CI step's command):

```bash
dune test internal/fixtures/local-demo/test/ --force
```

with `KAFKA_SECURITY_PROTOCOL=plaintext KAFKA_BROKERS=localhost:9092
SCHEMA_REGISTRY_URL=http://localhost:8081 REDPANDA_ADMIN_URL=http://localhost:9644
POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sol_dev` (`LOKI_URL` optional; the Loki
cases self-skip without it).

Observed 2026-10-01 against the local Redpanda (`:9092`/`:8081`/`:9644`), Postgres (`sol_dev`)
and Loki (`:3100`): **`Test Successful … 19 tests run`**, reproduced across repeated runs and
after dropping every shared table. The outbox suite reports:

```
[OK] outbox-facts-to-jobs 0 the declared topic was created at the declared partition count
[OK] outbox-facts-to-jobs 1 a rolled-back transaction leaves no domain row, intent, fact or effect
[OK] outbox-facts-to-jobs 2 with the broker unavailable the intent is held, and recovery publishes it once
[OK] outbox-facts-to-jobs 3 a duplicate fact delivery leaves one domain row and one independent effect
[OK] outbox-facts-to-jobs 4 a blocked earlier event does not let a later one for the same key publish first
[OK] outbox-facts-to-jobs 5 a crash between broker ack and the row mark duplicates, never gaps or inverts
[OK] outbox-facts-to-jobs 6 a transient job failure retries in sol-jobs and eventually succeeds once
[OK] outbox-facts-to-jobs 7 Fail stops the consumer with no application retry or DLQ topic
[OK] outbox-facts-to-jobs 8 the outbox and worker metrics are exposed
[OK] outbox-facts-to-jobs 9 outbox logs reached Loki
```

| Acceptance item | What the smoke asserts |
|---|---|
| Full flow; declared topic, key and partition; worker consumption; job execution; Sol logs and metrics | `sol-demo-outbox-e2e-<pid>` is created at the declared **3 partitions** (`Kafka_service.Admin.query_topic_partitions`); the keyed fact is consumed and its effect written; `sol_outbox_published_total`, `sol_worker_messages_total` and `sol_jobs_processed_total` are nonzero; outbox logs reach Loki |
| Forced rollback leaves no domain change, durable outbox event, Kafka fact or job | all three checked: no domain row, no `sol_outbox` row, no consumed fact (the effect follows) |
| Kafka unavailable after commit: durable, then published and marked only after acknowledgement | with the relay's broker boundary failing, the `sol_outbox` row is held and nothing is consumed; after recovery the row drains and the fact arrives once |
| Duplicate fact delivery uses the stable event id as the jobs dedupe key | two deliveries leave one domain row and one effect (idempotent insert + `~dedupe_key`) |
| `Fail` does not commit; consumer stops; operator-visible; no app retry/DLQ | `sol_worker_messages_total{status="fail"}` is recorded, the consumer stops, the fact is **redelivered** to a fresh member of the same group (proving the offset was not committed), and `<topic>.<group>.retry`/`.dlq` do not exist |
| Transient job failure retries and succeeds without replaying the acknowledged fact | the handler is invoked more than once and the effect exists exactly once |
| Same-key ordering; a blocked earlier event does not let a later one publish first | with the relay blocked, a later (`ord=2`) event is written before an earlier (`ord=1`) one for the same key; the consumer observes `[1; 2]` |
| Publish/mark crash boundary → duplicate, never gap or inversion | a relay that publishes then dies before the row's `DELETE` leaves the row; the restarted relay republishes it; the fact is delivered twice and the effect is still one |

**Recorded limits, not worked around.** The crash boundary is induced at the relay's publish
callback (publish to Kafka, then die before the mark) — the exact boundary, deterministic —
rather than a `SIGKILL` of a live process. Same-key-same-partition is Kafka's own guarantee
and is covered by the BUG-099 integration test in `framework/ocaml/kafka-eio-service`; this
smoke asserts the ordering that depends on it. The broker outage is simulated at the relay's
publish boundary rather than by stopping the broker, again for determinism.

### Documentation

The supported split is already where an app author reads it — `docs/guides/TUTORIAL.md`
§ The worker and `examples/pluto/app/comms/notify_worker` (FEAT-121). This ticket adds the
executable proof rather than a second explanation.

**TypeScript parity (DEC-022):** the TypeScript packages have no outbox or job queue, so the
flow cannot be exercised in TypeScript; that gap had no tracking ticket, so **FEAT-124** is
filed for the TypeScript outbox. The consumer half — a redelivered fact must not double the
TypeScript consumer's own effect — is tracked by **FEAT-123** (`BACKLOG`), whose trigger is
the next `@sol-fab/*` release.

**Demo/example coverage:** the fixture *is* the runnable example, now covering the full
composition and its failure boundaries; the deployed path is unchanged and still covered by
`golden-path-smoke`.
