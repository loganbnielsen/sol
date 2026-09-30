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
