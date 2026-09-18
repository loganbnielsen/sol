# sol-jobs — Durable Leased Job Library

## What it is

`sol-jobs` is Sol's Postgres-backed durable job queue: "do this eventually, retry with backoff, don't block on it" for independent units of work, without a second broker. It is a **library**, not a fourth deployable primitive (FEAT-077, DEC-021) — `Make(J).run` is hosted by an ordinary generated `-worker` binary, the primitive with no HTTP surface and the natural home for long-running background execution. There is no `sol new jobs` app type and no separate deploy topology; a `-worker` binary that calls `Sol_jobs.Make(J).run` instead of `Worker.Make(W).run` is still a `-worker` by runtime topology, it just processes a Postgres queue instead of a Kafka topic.

**Runtime topology and programming model are separate axes (DEC-021):**

| Work model | Substrate | Primitive |
|---|---|---|
| Stream/event consumption | Kafka | `sol-worker` (`Worker.Make`/`Make_with_retry`) |
| Durable independent jobs | Postgres | `sol-jobs` (`Sol_jobs.Make`), hosted by a `-worker` |

`sol-worker`/Kafka says "this happened" (a fact about the world, ordered per partition, one shared log any number of consumer groups can independently replay). `sol-jobs`/Postgres says "this must happen" (a unit of work with an owner, claimed once, retried until it succeeds or is given up on). Reach for `sol-jobs` when a piece of work is independent of any other event's ordering — sending a welcome email, generating a PDF, retrying a webhook delivery — and reach for `sol-worker` when correctness depends on processing events for the same key in order. Do not use `sol-jobs` merely because a job "happens to relate to" an earlier one; that is what Kafka's partition ordering is for.

**The one thing Kafka structurally cannot give you:** transactional enqueue. `Sol_jobs.Make(J).enqueue` issues a plain `INSERT`, so calling it with the `pool` handle from inside `Db.transaction`'s callback enqueues the job in the *same* Postgres transaction as whatever application state change caused it — no dual-write hole between "the order was placed" and "the confirmation-email job exists." A Kafka publish can never join a Postgres transaction.

## Module type

```ocaml
module type JOB = sig
  type t
  val kind : t -> string
  val encode : t -> string
  val decode : string -> (t, string) result
  val handle : t -> (unit, string) result
end
```

One `Make(J)` instance owns one shared job table and one polling loop. An app's `t` is its own sum type covering every kind of job it enqueues:

```ocaml
type job =
  | Send_welcome_email of { user_id : string }
  | Generate_pdf of { report_id : string }

module J = struct
  type t = job
  let kind = function
    | Send_welcome_email _ -> "send_welcome_email"
    | Generate_pdf _ -> "generate_pdf"
  let encode t = (* Yojson.Safe.to_string ... *)
  let decode s = (* Yojson.Safe.from_string, then decode ... *)
  let handle = function
    | Send_welcome_email { user_id } -> Emails.send_welcome user_id
    | Generate_pdf { report_id } -> Reports.generate report_id
end
```

Multiple job "kinds" are just constructors of one `t` — the same way an app's Kafka `MESSAGE` type can carry a variant payload. `kind` is a label for observability (metrics/logs) only, never used for routing, storage identity, or dispatch — dispatch is `J.handle`'s own pattern match.

`decode`'s `Error _` is treated exactly like a `handle` failure: retried per the configured `retry_policy`, eventually terminal. There is no separate poison-message path the way Kafka's decode-error handling needs one — unlike a Kafka partition, one bad row can never block any other job's claim.

## Job table

`sol-jobs` does not create or migrate its own table — an app author adds a migration for it, same as any other Sol-managed table:

```sql
CREATE TABLE IF NOT EXISTS sol_jobs (
  id           SERIAL      PRIMARY KEY,
  kind         TEXT        NOT NULL,
  payload      TEXT        NOT NULL,
  status       TEXT        NOT NULL DEFAULT 'pending',  -- 'pending' | 'failed'
  attempts     INT         NOT NULL DEFAULT 0,
  run_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  locked_until TIMESTAMPTZ,
  last_error   TEXT,
  inserted_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sol_jobs_claim_idx
  ON sol_jobs (run_at)
  WHERE status = 'pending';
```

The table name (`sol_jobs`) is fixed, not configurable — one app, one job table, matching FEAT-077's non-goal against a pluggable/configurable backend surface.

## Claim, lease, and retry mechanics

Each poll tick claims at most one due job with a single atomic statement:

```sql
UPDATE sol_jobs
SET locked_until = now() + (?::float8 * interval '1 second'),
    attempts = attempts + 1
WHERE id = (
  SELECT id FROM sol_jobs
  WHERE status = 'pending'
    AND run_at <= now()
    AND (locked_until IS NULL OR locked_until <= now())
  ORDER BY run_at
  FOR UPDATE SKIP LOCKED
  LIMIT 1
)
RETURNING id, kind, payload, attempts
```

`FOR UPDATE SKIP LOCKED` is the whole mechanism: Postgres's own row locking gives mutual exclusion across any number of pollers (multiple replicas of the same `-worker`, or multiple distinct `Make` instances sharing the table) with no coordinator, no `LISTEN`/`NOTIFY`, no external lease service. This is a **polling** claim loop by design (FEAT-077 non-goal: no `LISTEN`/`NOTIFY` push) — `poll_interval_s` (default `1.0`) is how long the loop sleeps when it finds nothing claimable; it never sleeps between consecutive jobs while the queue is non-empty.

The claim query updates `locked_until` and commits immediately — `J.handle` then runs **outside** any open database transaction or connection hold. This matters for a Postgres connection pool of limited size: a slow job never ties up a pooled connection for its own duration, only for the brief claim/finalize queries around it. `locked_until` (`lease_s`, default `300.0`) exists purely as the crash-recovery mechanism: if this process dies or is killed mid-`handle`, the row's lease eventually expires and another poller (or this same process, restarted) can reclaim it. A clean run always finalizes well before the lease expires; `lease_s` only needs to comfortably exceed the slowest realistic `J.handle` call.

On completion:

- **`Ok ()`** — the row is deleted. Completed jobs are not retained.
- **`Error msg`, attempts remaining** — `run_at` is pushed forward by the same backoff formula `sol-worker`'s `retry_policy` uses (`base_delay_s * 2^(attempt-1)`, jittered by `jitter_ratio`, clamped to `max_delay_s`), `locked_until` is cleared, and `last_error` records `msg`.
- **`Error msg`, attempts exhausted** — `status` becomes `'failed'` (terminal — the claim query's `WHERE status = 'pending'` never selects it again), `last_error` records the final message. A failed row stays in the table for operator visibility, the closest thing `sol-jobs` has to a DLQ.

`retry_policy`'s shape and default (`base_delay_s = 1.0; max_delay_s = 600.0; max_attempts = 5; jitter_ratio = 0.1`) intentionally bounds retries by default — `sol-jobs` is a durable at-least-once queue, not an infinite-retry stream consumer, so a poison job lands in `'failed'` rather than retrying forever unless an app explicitly opts into `max_attempts < 0`.

## Entrypoint

```ocaml
module Make (J : JOB) : sig
  val enqueue : Pg_db.pool -> ?run_at:float -> J.t -> (unit, Pg_error.t) result

  val run
    :  env:(_, _, _, _) Sol_env.timed
    -> pool:Pg_db.pool
    -> ?retry_policy:Sol_jobs.retry_policy
    -> ?poll_interval_s:float
    -> ?lease_s:float
    -> ?ot:Sol_obs.t
    -> ?metrics_port:int
    -> ?on_ready:(unit -> unit)
    -> ?stop:unit Eio.Promise.t
    -> ?max_jobs:int
    -> unit
    -> (unit, Sol_jobs.run_error) result
end
```

`run`'s shape deliberately mirrors `Worker.Make(_).run` (`env`/`ot`/`metrics_port`/`on_ready`/`stop`) so a `-worker` hosting `sol-jobs` looks and behaves like any other Sol primitive: `?ot:Sol_obs.t` wires the same logs/metrics/traces facade, exposing `sol_jobs_processed_total{status,kind}` (`status`: `ok`/`retry`/`failed`) and `sol_jobs_job_duration_seconds` on `GET /metrics`, scraped by Prometheus the same way.

`run` returns `Error (\`Config msg)` immediately, before ever touching Postgres, if `retry_policy.max_attempts = 0` — a `0` value can never mean anything valid (it isn't "no retry", `max_attempts = 1` is; it isn't "unlimited", negative is) so it is rejected up front rather than silently misbehaving the first time a job fails, the same fail-fast discipline FEAT-078 applied to `sol-worker`'s mandatory `retry_strategy`.

## Example: transactional enqueue

```ocaml
let accept_order pool order =
  Db.transaction pool (fun pool ->
    let* () = Orders.insert pool order in
    Jobs.enqueue pool (Send_confirmation_email { order_id = order.Orders.id }))
```

If the transaction commits, the order row and the job row both exist. If it rolls back, neither does. There is no window where the order exists but the job was never enqueued (or vice versa) — the failure mode a Kafka publish outside the same transaction cannot close.

## Non-goals

- No RabbitMQ, ElasticMQ, or SQS-compatible abstraction — Postgres only.
- No `LISTEN`/`NOTIFY` push mechanism — polling is the ladder-correct start.
- No new deployable app suffix (`sol new jobs`) or CLI scaffold changes — `Sol_jobs.Make(J).run` is called from a hand-written or generated `-worker`'s `bin/main.ml` like any other library call.
- No configurable/pluggable job-backend, no configurable table name.
- No Kafka-style ordering, partitioning, or per-key sequencing — see "What it is" above for when that means reaching for `sol-worker` instead.
