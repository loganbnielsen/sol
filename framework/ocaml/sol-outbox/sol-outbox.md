# sol-outbox

A Postgres-backed **transactional outbox**: an application writes its domain state change
and the event describing it in **one transaction**, and a relay publishes those events to
Kafka. It is the producer-side half of DEC-021's 2026-09-29 amendment.

```text
domain same-key serialization/version order
      → transactional outbox (atomic state + publication intent)
      → ordered per-key publication
      → Kafka partition order
```

The transactional system of record *records and preserves* the order the domain
establishes. It is not a domain-ordering API, and generic commit order is not the contract.

## The contract

**Per-key order, with at-least-once publication.** For a given key, events are published in
the order the domain established, and publication is at-least-once: a duplicate may be
emitted, but never after a later event for that key, and never a gap.

Duplicates are possible; **gaps and inversions are not.** Consumers must be idempotent
(version-aware) and must not need to reorder.

**Atomicity is at the transaction, not at Kafka.**

```text
state transaction commits  ⇔  its outbox record commits
committed unpublished outbox record  →  eventually published
```

"An event exists iff the state change committed" holds of the **outbox record — the
publication intent** — never of the Kafka record, because publication is asynchronous.
That distinction is the whole reason the outbox exists.

**The ordering token comes from the domain.** `publish` takes `ord` rather than inventing
one: it must be the caller's per-key order token, assigned while that key is serialized (a
per-key version, or a value read under the same lock or compare-and-set that makes the
mutation serial). The outbox deliberately has no sequence generator and no global-ordering
fallback, because "order by the global sequence" is exactly how generic commit order would
be smuggled back in as domain order. A unique index on `(aggregate_key, ord)` refuses a
token collision instead of quietly publishing two events in one position.

## The table

The workspace owns the migration that creates it (`db/migrations/0003_sol_outbox.sql` in
the scaffold, `examples/pluto` and `internal/fixtures/venus`):

```sql
CREATE TABLE IF NOT EXISTS sol_outbox (
  id            BIGSERIAL   PRIMARY KEY,
  kind          TEXT        NOT NULL,
  aggregate_key TEXT        NOT NULL,
  ord           BIGINT      NOT NULL,
  payload       TEXT        NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS sol_outbox_key_ord_idx
  ON sol_outbox (aggregate_key, ord);
```

**Rows are deleted once published.** Kafka is the durable replay log; Postgres must not
become a second one. So there is nothing to retain, no `published_at` column to keep true,
and no bloat to sweep — the table holds only what is not yet published. `created_at` exists
for the lag metric and for a stable scan order, not for retention.

The scan is `kind = ANY(E.kinds) AND ord = (SELECT min(ord) … WHERE aggregate_key =
o.aggregate_key)`, one row per key, ordered by `id`. The `kind` predicate scopes a relay to the
rows it owns, so a table shared by more than one relay has each row published by exactly its
owner's relay; the `(aggregate_key, ord)` index serves both the per-key minimum and the
uniqueness check — and, because a later event cannot be enqueued until the earlier one's row
has been deleted, it also carries per-key order *across* kinds.

## The relay protocol

For the oldest unpublished event of a key:

```text
produce → await the broker receipt
    ├── failure → leave unpublished, do not advance the key
    └── acknowledged → mark published (here: delete the row) → next event for that key
```

Two things it makes load-bearing:

- **"Published" means the broker acknowledged**, not "handed to the producer". The injected
  `publish` callback must not return `Ok` before the delivery receipt resolves — the app
  builds it on `Kafka.Producer.produce_await` and `Eio.Promise.await`. Marking on the
  promise instead reproduces the silent-loss bug already recorded against `publish_raw`.
- **The invariant is "never advance past an unpublished row", and its price is duplicates
  rather than loss.** A relay that marked *before* publishing, to stop a second relay
  double-publishing, would lose the event permanently if it died in between. That is the
  wrong trade, and it is why the protocol is publish-then-mark-on-receipt.

A publish that cannot succeed blocks **later events for that key** — which is correct — and
is visible as lag, not a silent gap. The relay does not exit; it retries on the poll
interval, so a broker outage drains once the broker returns.

**v1 is one logical relay owner per kind.** A table may be shared by several relays, one per
`E.kinds` set — each publishes only the kinds it owns, so every row has exactly one owner.
Two owners of the *same kind* are a correctness problem, not a performance one: they can
invert a key, and leases alone do not prevent it, because an expired-but-alive relay can still
publish and a plain producer carries no fencing token. Scaling is a trigger, not a design:
when measured relay throughput is inadequate, an ownership/fencing mechanism is spiked then.
No mechanism is chosen in advance.

## Public API

```ocaml
module type EVENT : sig
  type t

  val kind : t -> string
  val kinds : string list
  val encode : t -> string
end

type run_error =
  [ `Config of string
  | `Database of string
  ]

val run_error_to_string : run_error -> string

type publication =
  { kind : string
  ; key : string
  ; ord : int64
  ; payload : string
  }

val publish
  :  Pg_db.tx
  -> key:string
  -> ord:int64
  -> payload:string
  -> kind:string
  -> (unit, Pg_error.t) result

module Make (E : EVENT) : sig
  val publish : Pg_db.tx -> key:string -> ord:int64 -> E.t -> (unit, Pg_error.t) result

  val relay
    :  env:(_, _, _, _) Sol_env.timed
    -> pool:Pg_db.pool
    -> publish:(publication -> (unit, string) result)
    -> ?poll_interval_s:float
    -> ?batch:int
    -> ?ot:Sol_obs.t
    -> ?metrics_port:int
    -> ?on_ready:(unit -> unit)
    -> ?stop:unit Eio.Promise.t
    -> unit
    -> (unit, run_error) result
end

module For_testing : sig
  val pending
    :  Pg_db.pool
    -> ?limit:int
    -> unit
    -> ((string * int64) list, Pg_error.t) result

  val pending_count : Pg_db.pool -> (int, Pg_error.t) result
end
```

`publish` takes `Pg_db.tx`, not `Pg_db.pool`, so it participates in the caller's
transaction and **cannot** be called outside one — `EXP-033` made transaction scope a type,
matching `Sol_jobs.enqueue`. The two compose in a single transaction: a state change, an
event intent and a job can commit together or not at all.

The relay takes `pool`, because it is its own process with its own lifecycle, and the
publish callback is injected so this package does not depend on the Kafka layer. A
workspace's relay builds that callback from its `Kafka_service` topic handles, passing the
publication's `key` as the Kafka key so downstream per-partition order is the published
order.

## Metrics

| Metric | Labels | Meaning |
|---|---|---|
| `sol_outbox_published_total` | `kind`, `status` (`ok`, `failed`, `mark_failed`) | Events whose publication was acknowledged, and the failures |
| `sol_outbox_pending` | `kind` | Rows waiting to be published |
| `sol_outbox_oldest_pending_seconds` | `kind` | Age of the oldest unpublished row: the publication lag |

Lag is reported at `kind` granularity rather than per key on purpose: a key label is
unbounded cardinality, and a key that is blocked raises its kind's oldest-pending age
immediately — which is the signal an alert needs. Alert on
`sol_outbox_oldest_pending_seconds` crossing a threshold.

Both gauges are a complete snapshot of the relay's own `E.kinds`: every declared kind is emitted on
every successful sample, so a drained or never-used kind reports `0` instead of keeping a stale
positive value, and a kind owned by another relay is never emitted. A failed snapshot query emits
nothing for that gauge and warns with the database error, so a query failure is never reported as
a zero backlog.

## What it does not prove, and is not

- The ordering guarantee is as good as the caller's `ord`. Passing an insertion counter
  instead of a domain token gives commit order wearing an ordering token's clothes — the
  one thing this package cannot check for you.
- Consumer idempotency is required, not provided: a duplicate is a legal outcome. State and
  document the consumer's dedup story (an event id, a version check, an upsert).
- Not a general event log, not a Kafka replacement, and consumers never poll the outbox.
- Not CDC/Debezium: an application-managed outbox is explicit and needs no connector.
- Not a scheduler or job queue — that is `sol-jobs`. There is no per-key ordering guarantee
  in `sol-jobs`; that stays an explicit non-goal.
- No pluggable storage backend and no distributed relay. Postgres is Sol's storage layer,
  and a backend enum gets designed the day a second implementation exists — the pattern is
  the portable part, not the package.
