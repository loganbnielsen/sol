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

## Completion notes

Implemented as `framework/sol-jobs/lib/sol_jobs.ml`/`.mli`, matching the
design above closely:

- `module type JOB = sig type t val kind val encode val decode val handle end`
  — one `Make(J)` instance per app, one shared `sol_jobs` table, one
  polling claim loop. `t` is the app's own sum type covering every job
  kind it enqueues (mirrors how a Kafka `MESSAGE` type carries a variant
  payload) — `kind` is an observability label only, never used for
  routing or dispatch (that's `J.handle`'s own pattern match).
- Claim query matches the design's SQL shape exactly (`status`,
  `run_at <= now()`, `FOR UPDATE SKIP LOCKED`), plus a `locked_until`
  lease so `J.handle` runs outside any open DB transaction/connection —
  a slow job never ties up a pooled connection, only the brief
  claim/finalize queries around it.
- `retry_policy` reuses `Kafka.Consumer.retry_policy`'s exact shape and
  backoff formula (`base_delay_s * 2^(attempt-1)`, jittered, clamped to
  `max_delay_s`) but is reimplemented independently — no `kafka-eio`
  dependency pulled into a Postgres-only library — down to the same
  self-seeded, mutex-protected `Random.State.t` discipline. Default
  `max_attempts = 5` (bounded, unlike Kafka's indefinite-by-default): a
  durable at-least-once queue should land a poison job in a terminal
  `'failed'` state, not retry forever, unless an app explicitly opts into
  `max_attempts < 0`.
- `run` returns `Error (\`Config _)` immediately, before ever touching
  Postgres, on an invalid `retry_policy` (`max_attempts = 0`) — same
  fail-fast discipline FEAT-078 applied to `sol-worker`'s mandatory
  `retry_strategy`.
- `run`'s shape (`env`/`ot`/`metrics_port`/`on_ready`/`stop`) deliberately
  mirrors `Worker.Make(_).run`, including the same
  `Obs_eio.register_counter_and_histogram` pattern
  (`sol_jobs_processed_total{status,kind}`,
  `sol_jobs_job_duration_seconds`) — a `-worker` hosting `sol-jobs` is
  observable exactly the way any other Sol primitive is.
- No CLI/manifest changes at all: `Sol_jobs.Make(J).run` is called from a
  hand-written or generated `-worker`'s `bin/main.ml` like any other
  library call, matching the non-goal against a new app suffix.

**Demo/example coverage:** `examples/local-demo` now demonstrates
transactional enqueue end-to-end. The fulfillment worker's handler wraps
the `fulfilled_orders` insert and a `send_confirmation_email` job enqueue
in one `Pg_db.transaction` — the job exists if and only if the order does,
the guarantee a Kafka publish structurally cannot offer. A second daemon
fiber hosts `Sol_jobs.Make(EmailJob).run` (a jobs-worker), claims the job,
and "sends" the email. New migration
`examples/local-demo/migrations/0002_sol_jobs.sql` creates the table.
Verified with a real end-to-end run against live Kafka + Postgres (not
simulated): all 3 orders accepted, fulfilled, and their confirmation-email
jobs claimed and completed; `sol_jobs_processed_total` and
`sol_jobs_job_duration_seconds` both populated in the Prometheus snapshot;
0 failed assertions, including the two new ones
(`sol_jobs_processed_total > 0` and "all confirmation-email jobs
completed").

**Testing:** `framework/sol-jobs/test/test_sol_jobs.ml` covers the backoff
formula (deliberately close copies of `kafka-eio`'s own `backoff_s` unit
tests, to catch the two formulas drifting apart: bounded, non-negative,
deterministic given an injected rng, no-jitter-when-ratio-zero) and
`retry_policy` validation (`max_attempts = 0` rejected;
positive/negative accepted) — no live Postgres needed for these, matching
the "unit" test suite's no-infra-required contract. Claim/lease/retry
correctness itself is exercised for real by the local-demo run above
rather than a separate synthetic Postgres integration-test target.

`sol-worker.md` updated: removed its now-stale "sol-jobs remains a
separate future primitive" line (FEAT-077 is done) in favor of pointing
at `sol-jobs.md` for independent-work semantics.

**TS parity:** Not included in FEAT-077. `sol-jobs` introduces a new
language-facing programming model — durable leased jobs alongside Kafka's
stream consumption (DEC-021) — so TypeScript parity should be evaluated as
its own capability rather than implicitly assumed from the OCaml
implementation. Recorded for the cross-language inventory in FEAT-080; this
defers the question, it does not answer it.
