---
id: FEAT-112
type: feature
severity: high
title: Make sol-jobs enqueue idempotent, so the Kafka-to-jobs handoff is at-least-once safe
source: DEC-021 amendment (2026-09-29) — Kafka distributes facts; jobs perform retryable work
---

**Depends on:** None.

`FEAT-113` (removing Kafka message-level retry and application-level `Dead_letter`)
depends on this ticket: it makes Kafka → `sol-jobs` the endorsed composition for
independently retryable work, which is only safe once `enqueue` deduplicates.

**Related:** `DEC-021` (the amendment, §5), `FEAT-111` (the outbox — the
producer-side half of the same boundary), `FEAT-113` (removing Kafka message retry and
application-level `Dead_letter`), `framework/ocaml/sol-jobs/sol-jobs.md`.

## The problem

Under the target model a worker consumes a Kafka fact and hands independent work to
`sol-jobs`:

```text
consume fact → enqueue job → commit Kafka offset
```

`enqueue` and the offset commit are in different systems, so this is a new
at-least-once boundary:

```text
INSERT job succeeds
      │
Kafka commit fails
      │
fact redelivered
      │
INSERT job again
```

`Sol_jobs.Make(J).enqueue` issues a plain `INSERT`, so today the second delivery
enqueues a second job and correctness rests entirely on every job handler being
idempotent. That is the wrong place to carry the burden: under the target
architecture this handoff is one of the intended composition points, not an edge
case.

## Required behaviour

- `enqueue` accepts a **dedupe key** — the event's stable id, not a job id — with a
  uniqueness constraint on `(kind, dedupe_key)`.
- A duplicate enqueue is **success**, not an error: the caller cannot distinguish "I
  inserted it" from "someone already did", and should not have to.
- The guarantee is scoped to what the constraint can actually enforce. `sol-jobs`
  deletes a completed row, so a redelivery *after completion* would enqueue again.
  Decide and record one of:
  - a separate dedupe marker with a TTL (keeps the queue clean, bounds storage), or
  - retaining terminal rows for a retention window before deletion, or
  - explicitly not covering post-completion redelivery, with the resulting
    handler-idempotency obligation stated.
  The choice defines the real guarantee; do not leave it implicit.
- A `dedupe_key` that is omitted keeps today's at-least-once, non-deduplicated
  behaviour, documented as such.
- Whether a caller can learn the existing job's id, or only that it was already
  enqueued, is part of the contract; record the chosen shape.
- The job table's declaration changes directly and every call site is updated in the
  same pass — pre-alpha, so no compatibility shim, alias, or version gate.

## Non-goals

- Not per-key ordering or sequencing in `sol-jobs`; that stays an explicit non-goal,
  and ordered work must not be moved here.
- Not a general-purpose idempotency framework for application handlers.
- Not a change to the claim/lease/backoff mechanics.

## Acceptance criteria

- A duplicate enqueue with the same `(kind, dedupe_key)` creates no second job and
  returns no error.
- A test simulates the Kafka handoff boundary: enqueue succeeds, the commit "fails",
  the fact is redelivered, enqueue is a no-op, and exactly one job executes.
- The post-completion redelivery case is covered by a test, or explicitly excluded
  and documented with its consequence.
- `sol-jobs.md` documents the dedupe contract, including what a caller may and may
  not assume.
- The uniqueness constraint is enforced in the database, not only in application
  code, and a concurrent-duplicate test proves it.

**Demo/example coverage:** the tutorial or `examples/pluto` must show the Kafka→jobs
handoff with an idempotent enqueue, since it is now the recommended composition.

**TypeScript parity:** required or explicitly deferred with a trigger. There is no TS
jobs package today, so this strengthens an existing gap rather than creating a new
one (DEC-022).

## Completion

Implemented 2026-09-30. Premise verified at `origin/main` `3e8705c5`: `enqueue` was a
plain `INSERT` with no uniqueness constraint, and the table had no dedupe column
(`sol_jobs.ml`, `sol-jobs.md`).

**The post-completion decision, recorded.** The ticket asked for one of three; this
takes the second — `sol-jobs` retains terminal rows for a retention window instead of
deleting them on completion. Reasoning: the case this handoff must actually survive
is a *replay*, where the redelivery arrives long after the first attempt finished and
the row would already be gone. A separate TTL'd dedupe marker would keep the queue
table smaller, but duplicates the lifecycle (a second table, a second sweep, two
writes per enqueue) for the same bounded guarantee, while the partial unique index on
`(kind, dedupe_key)` does the work of both. Omitting the key stays at-least-once, and
the horizon — how long a key stays occupied — becomes an explicit, tunable part of the
contract instead of an accident of delete-on-completion.

What changed: `enqueue ?dedupe_key` (`INSERT … ON CONFLICT (kind, dedupe_key) WHERE
dedupe_key IS NOT NULL DO NOTHING`; a duplicate is `Ok ()` and no job id is returned),
a `completed` terminal status carrying `finished_at`, and a sweep inside the poller
(`terminal_retention_s`, default 7 days; `sweep_interval_s`, default 60s).

**Demo/example coverage:** `internal/fixtures/local-demo` — the runnable Kafka→jobs
fixture — now enqueues with `~dedupe_key:msg.Message.order_id` in the same transaction
as the fulfilled-order insert, and `0003_sol_jobs_dedupe.sql` carries the new column
and indexes. It uses the order id because the demo event carries no event id; a real
application uses the event's stable id.

**TypeScript parity:** deferred with a trigger (DEC-022). There is no TS jobs package
at all today, so this deepens an existing gap rather than opening a new one; the
trigger is the same one already recorded for `sol-jobs` — the first TS application
that needs durable jobs.

**Validation:** `dune build` clean; 18 `sol_jobs_pg` tests, 5 new (repeated key,
concurrent duplicates, omitted key, redelivery after completion, expired-row sweep);
9 `local-demo` e2e tests including the jobs handoff and `sol_jobs_processed_total > 0`.
Full required CI on the PR head.

**Remaining limitation:** a redelivery older than the retention window re-enqueues.
That is why the window is stated as part of the contract, and why a handler that must
survive arbitrary replays stays idempotent.

**Adoption note:** the job table is app-owned and app-migrated, so this is a schema
change every existing workspace adopts — the full DDL and the dedupe contract are in
`sol-jobs.md` § Job table and § Deduplication.
