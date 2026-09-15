---
id: FEAT-077
type: feature
severity: low
source: messaging-substrate discussion 2026-09-14 (Kafka vs SQS/RabbitMQ/Pulsar for Sol worker semantics)
---

**Depends on:** None.

**Related:** DEC-021, FEAT-076.

Introduce `sol-jobs`, a Postgres-backed durable leased-job library, for
workloads that want "do this eventually, retry with backoff, don't block on
it" without Kafka — specifically to get transactional enqueue (job insert in
the same transaction as the application state change that caused it), which
Kafka cannot offer since a message publish can't join a Postgres
transaction.

## Status

Not blocked on a concrete workload. Durable independent background work is
a generic backend capability within Sol's intended platform scope;
DEC-021 establishes the semantic distinction from Kafka stream processing
(`sol-worker`/Kafka: "this happened"; `sol-jobs`/Postgres: "this must
happen"). A concrete workload's role going forward is **validation, not
permission**: it can still confirm the designed API is good and expose
missing requirements once this is built, but the platform doesn't need one
to justify the capability existing at all.

(Previously gated on "a concrete workload demonstrates this need" —
that premise question is resolved; the remaining question was only ever
prioritization against other work, which this promotion to
`READY_FOR_ENGINEERING` now answers.)

## Design (recorded now so it doesn't need re-deriving later)

- Backed by `pg-eio`, which every Sol app already provisions — no new
  infrastructure, no new `local infra up` service.
- Core query shape:
  ```sql
  SELECT ... FROM jobs
  WHERE status = 'pending' AND run_at <= now()
  FOR UPDATE SKIP LOCKED
  ```
  with `status`, `attempts`, `run_at`, `locked_until`, `last_error` columns;
  a polling claim loop, not `LISTEN`/`NOTIFY`.
- `sol-jobs` is a **library**, not a fourth deployable primitive: it is
  hosted by an ordinary `-worker` process (already the primitive with no
  HTTP surface and the natural home for long-running background execution),
  not a new `-jobs` app suffix.

## Non-goals (explicit, to prevent re-litigating)

- No RabbitMQ, ElasticMQ, or SQS-compatible abstraction.
- No `LISTEN`/`NOTIFY` push mechanism — polling is the ladder-correct start.
- No new deployable app suffix (`sol new jobs`).
- No configurable/pluggable job-backend — Postgres only, until something
  else is proven necessary.

## Acceptance criteria (once unblocked)

- `sol-jobs` supports insert-within-the-application-transaction, leased
  claim, backoff/retry, and terminal completion/failure.
- Hosted by a generated `-worker` binary — no new CLI app-type or deploy
  topology.
- Demo/example coverage per repo convention.
