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
  val kinds : string list
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
  let kinds = [ "send_welcome_email"; "generate_pdf" ]
  let encode t = (* Yojson.Safe.to_string ... *)
  let decode s = (* Yojson.Safe.from_string, then decode ... *)
  let handle = function
    | Send_welcome_email { user_id } -> Emails.send_welcome user_id
    | Generate_pdf { report_id } -> Reports.generate report_id
end
```

Multiple job "kinds" are just constructors of one `t` — the same way an app's Kafka `MESSAGE` type can carry a variant payload. Dispatch is `J.handle`'s own pattern match. `kind` labels metrics and logs, and it is also what a poller **claims by** (BUG-044): `kinds` lists every value `kind` can return, and a `Make(J)` poller claims only rows whose `kind` is in `J.kinds`. So separate `Make` instances with different job types can share the one table without claiming — and failing to decode — each other's jobs. Each kind is non-empty and uses only `a-z`, `0-9`, `_`, `.`, `-`; `run` refuses anything else with `` `Config ``, and `enqueue` refuses a job whose `kind` is not in `J.kinds`, because no poller would ever claim it.

`decode`'s `Error _` is treated exactly like a `handle` failure: retried per the configured `retry_policy`, eventually terminal. There is no separate poison-message path the way Kafka's decode-error handling needs one — unlike a Kafka partition, one bad row can never block any other job's claim.

## Workspace identity

Every row belongs to the workspace that enqueued it, and `sol-jobs` refuses to enqueue or poll without knowing which workspace it is: two workspaces can share one Postgres database and even the same job `kind` (Sol's local path starts one database for every workspace), and without an identity one workspace's poller would claim, run, retry or terminally fail the other's jobs — or sweep their terminal rows.

The identity is `SOL_WORKSPACE`, the workspace name. Sol's platform renders it into every workload's ConfigMap, so a deployed `-worker` has it without the app doing anything; a process run outside a workload (a local run, a test) must set it explicitly, the same way it sets `KAFKA_SECURITY_PROTOCOL`. There is no default: an absent, empty or malformed value is `` `Config `` from `run` and a refused enqueue from `enqueue`, never a shared queue. A workspace name is non-empty, at most 63 characters, and uses only `a-z`, `A-Z`, `0-9`, `_`, `.` and `-`.

## Job table

`sol-jobs` does not create or migrate its own table — an app author adds a migration for it, same as any other Sol-managed table:

```sql
CREATE TABLE IF NOT EXISTS sol_jobs (
  id           SERIAL      PRIMARY KEY,
  workspace    TEXT        NOT NULL,
  kind         TEXT        NOT NULL,
  payload      TEXT        NOT NULL,
  status       TEXT        NOT NULL DEFAULT 'pending',  -- 'pending' | 'completed' | 'failed'
  attempts     INT         NOT NULL DEFAULT 0,
  run_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  locked_until TIMESTAMPTZ,
  last_error   TEXT,
  dedupe_key   TEXT,
  inserted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS sol_jobs_claim_idx
  ON sol_jobs (workspace, run_at)
  WHERE status = 'pending';

CREATE UNIQUE INDEX IF NOT EXISTS sol_jobs_dedupe_idx
  ON sol_jobs (workspace, kind, dedupe_key)
  WHERE dedupe_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS sol_jobs_terminal_idx
  ON sol_jobs (workspace, finished_at)
  WHERE status <> 'pending';
```

The table name (`sol_jobs`) is fixed, not configurable — one app, one job table, matching FEAT-077's non-goal against a pluggable/configurable backend surface. `workspace` is `NOT NULL` and every statement names it — enqueue, claim, completion, retry, terminal failure, lease renewal and sweep — so the row's owner is a column the database enforces, not a convention the queries remember.

## Deduplication: the Kafka → jobs handoff

`enqueue ?dedupe_key` makes handing work from a Kafka fact to a job idempotent. The dedupe key is the **event's** stable id, not a job id:

```ocaml
Db.transaction pool (fun tx ->
  Jobs.enqueue tx ~dedupe_key:event.id (Send_confirmation_email { order_id }))
```

- The uniqueness constraint on `(workspace, kind, dedupe_key)` lives in the database, not only in `enqueue`: two concurrent enqueues of the same key insert one row, and two workspaces reusing one key each keep their own.
- **A duplicate is success.** `enqueue` returns `Ok ()` whether it inserted the row or found one already there — the caller cannot, and should not have to, tell those apart. No job id is returned, so nothing else about the existing row is observable.
- Omitting `~dedupe_key` keeps the plain at-least-once insert: two calls enqueue two jobs. That is the right shape when the caller has no stable id to offer.

**How long a key stays occupied.** A finished job's row is retained for `~terminal_retention_s` (default 604800s = 7 days) and only then swept, so its dedupe key blocks a re-enqueue for that whole window. That is the point: a Kafka redelivery usually arrives after the first attempt has already finished, and deleting the row on completion would re-enqueue exactly then.

```text
enqueue evt-1 → handle → completed ─┐
                                    │  row retained: a redelivery of evt-1 is a no-op
redeliver evt-1 ────────────────────┘
```

Past the window the key is free again, so a redelivery *older than the window* enqueues a second job. **That horizon is part of the contract**: choose a window longer than the redelivery you need to absorb, and keep a handler idempotent if it must survive anything older. The alternative — retaining forever — would grow the job table with throughput.

Sweeping happens inside the poller (`~sweep_interval_s`, default 60s), so it needs no separate process or cron. `status = 'completed'` rows are never claimed: the claim query and its partial index both filter on `'pending'`.

## Claim, lease, and retry mechanics

Each poll tick claims at most one due job with a single atomic statement:

```sql
UPDATE sol_jobs
SET locked_until = now() + (?::float8 * interval '1 second'),
    attempts = attempts + 1
WHERE id = (
  SELECT id FROM sol_jobs
  WHERE status = 'pending'
    AND kind = ANY(string_to_array(?, ','))   -- J.kinds, comma-joined
    AND run_at <= now()
    AND (locked_until IS NULL OR locked_until <= now())
  ORDER BY run_at
  FOR UPDATE SKIP LOCKED
  LIMIT 1
)
RETURNING id, kind, payload, attempts
```

`FOR UPDATE SKIP LOCKED` is the whole mechanism: Postgres's own row locking gives mutual exclusion across any number of pollers (multiple replicas of the same `-worker`, or multiple distinct `Make` instances sharing the table — each claims only its own `J.kinds`) with no coordinator, no `LISTEN`/`NOTIFY`, no external lease service. This is a **polling** claim loop by design (FEAT-077 non-goal: no `LISTEN`/`NOTIFY` push) — `poll_interval_s` (default `1.0`) is how long the loop sleeps when it finds nothing claimable; it never sleeps between consecutive jobs while the queue is non-empty.

The claim query updates `locked_until` and commits immediately — `J.handle` then runs **outside** any open database transaction or connection hold. This matters for a Postgres connection pool of limited size: a slow job never ties up a pooled connection for its own duration, only for the brief claim/renew/finalize queries around it. `locked_until` (`lease_s`, default `300.0`) is the crash-recovery mechanism: if this process dies or is killed mid-`handle`, the row's lease expires and another poller can reclaim it after about one lease.

While `J.handle` runs, a sibling fiber renews the lease every `lease_s / 3` using the claimed row's `id` and `attempts`. A renewal succeeds only while that same claim is pending and its lease is still current. A long handler that yields to Eio stays exclusive. If renewal loses the claim, it stops and logs the loss. A handler that blocks the Eio domain or an unavailable database can still miss renewal; keep handlers cooperative and idempotent.

Fenced finalization protects the queue if a lease is lost:

The claim increments `attempts` and returns it, and the complete (`DELETE`), retry and fail statements all match `id = ? AND attempts = ?`. A stale holder's finalize therefore matches no row: it cannot delete the job out from under the new holder or clear its lease. The loss is logged (`sol-jobs: lease lost`, with `job_id`, `attempt`, `action`), and the stale outcome is not recorded — the new holder's is.

Warnings go through `ot` when given and stderr otherwise. Keep handlers idempotent, since crash recovery is at-least-once.

On completion:

- **`Ok ()`** — the row is deleted. Completed jobs are not retained.
- **`Error msg`, attempts remaining** — `run_at` is pushed forward by the same backoff formula `sol-worker`'s `retry_policy` uses (`base_delay_s * 2^(attempt-1)`, jittered by `jitter_ratio`, clamped to `max_delay_s`), `locked_until` is cleared, and `last_error` records `msg`.
- **`Error msg`, attempts exhausted** — `status` becomes `'failed'` (terminal — the claim query's `WHERE status = 'pending'` never selects it again), `last_error` records the final message. A failed row stays in the table for operator visibility, the closest thing `sol-jobs` has to a DLQ.

`retry_policy`'s shape and default (`base_delay_s = 1.0; max_delay_s = 600.0; max_attempts = 5; jitter_ratio = 0.1`) intentionally bounds retries by default — `sol-jobs` is a durable at-least-once queue, not an infinite-retry stream consumer, so a poison job lands in `'failed'` rather than retrying forever unless an app explicitly opts into `max_attempts < 0`.

An expired lease from a worker crash counts as an unfinished attempt. The next claim atomically moves the row to `'failed'` once `max_attempts` is reached, without calling the handler again; `last_error` names the unfinished attempt. Ordinary exceptions from `decode` or `handle` count as failed attempts through the same retry/fail path as returned errors. Cancellation and fatal runtime exceptions still propagate.

## Entrypoint

```ocaml
module Make (J : JOB) : sig
  val enqueue : Pg_db.tx -> ?run_at:float -> J.t -> (unit, Pg_error.t) result

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
    -> ?max_claim_failures:int
    -> unit
    -> (unit, Sol_jobs.run_error) result
end
```

`run`'s shape deliberately mirrors `Worker.Make(_).run` (`env`/`ot`/`metrics_port`/`on_ready`/`stop`) so a `-worker` hosting `sol-jobs` looks and behaves like any other Sol primitive: `?ot:Sol_obs.t` wires the same logs/metrics/traces facade, exposing `sol_jobs_processed_total{status,kind}` (`status`: `ok`/`retry`/`failed`) and `sol_jobs_job_duration_seconds` on `GET /metrics`, scraped by Prometheus the same way.

`run` returns `Error (\`Config msg)` immediately, before ever touching Postgres, if `retry_policy.max_attempts = 0` — a `0` value can never mean anything valid (it isn't "no retry", `max_attempts = 1` is; it isn't "unlimited", negative is) so it is rejected up front rather than silently misbehaving the first time a job fails. Invalid `J.kinds` is the same kind of `` `Config `` error.

The same boundary validates every timing input before the first database read or signal registration (CODEX_STYLE_AUDIT-079): `lease_s` and `poll_interval_s` must be finite and greater than zero (a nonpositive lease would let a second poller reclaim a job immediately; a nonpositive interval reaches `Eio.Time.sleep`), and `retry_policy`'s `base_delay_s`/`max_delay_s` must be finite and non-negative while `jitter_ratio` must be finite and within `[0, 1]`. `0` retry delays stay valid (an app may want immediate retries), negative `max_attempts` stays valid (unlimited), and non-finite values (`nan`/`infinity`) are refused rather than reaching a sleep, `Random` or the claim SQL.

Database trouble is loud (BUG-044). `run` reads the `sol_jobs` table before its first claim and returns `` Error (`Database msg) `` if it cannot — a missing migration is a startup error, not an idle-looking loop. A claim query that fails is logged (to `ot`, or to stderr without it) and retried every `poll_interval_s`; `max_claim_failures` consecutive failures (default `30`) end `run` with `` `Database ``, so a `-worker` whose database stays unreachable exits and is restarted visibly rather than polling in silence. Every other database failure the loop meets (a failed completion, retry or terminal mark) is logged the same way.

## Example: transactional enqueue

```ocaml
let accept_order pool order =
  Db.transaction pool (fun tx ->
    let* () = Orders.insert tx order in
    Jobs.enqueue tx (Send_confirmation_email { order_id = order.Orders.id }))
```

If the transaction commits, the order row and the job row both exist. If it rolls back, neither does. There is no window where the order exists but the job was never enqueued (or vice versa) — the failure mode a Kafka publish outside the same transaction cannot close.

The guarantee is **enforced by the type, not by convention**. `enqueue` takes
`Pg_db.tx`, which only `Pg_db.transaction`'s callback can produce, so an enqueue that
would commit on its own — the shape that silently loses the atomicity — does not
compile. `Db.exec`/`find`/`collect` and the `Pg_table` accessors are polymorphic in the
capability, so the same helpers work in both places and there is no second API to keep
in step.

What the type does **not** prove: that you are *currently* inside the transaction. A
`pg_db.tx` is an ordinary value, so a callback can store it and use it after commit.
The compiler establishes that you entered a transaction, not that it is still open.
Closing that needs linearity or regions, which we do not have cheaply; treat a stored
`tx` as a bug, and keep the atomicity test — both rows commit together and roll back
together — as the behavioural check.

## Non-goals

- No RabbitMQ, ElasticMQ, or SQS-compatible abstraction — Postgres only.
- No `LISTEN`/`NOTIFY` push mechanism — polling is the ladder-correct start.
- No new deployable app suffix (`sol new jobs`) or CLI scaffold changes — `Sol_jobs.Make(J).run` is called from a hand-written or generated `-worker`'s `bin/main.ml` like any other library call.
- No configurable/pluggable job-backend, no configurable table name.
- No Kafka-style ordering, partitioning, or per-key sequencing — see "What it is" above for when that means reaching for `sol-worker` instead.
