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
