---
id: FEAT-132
type: feature
severity: high
title: "OCaml reference application: 'Pluto orders' end to end (request -> tx -> outbox -> Kafka -> worker -> job -> read-back)"
source: internal/qualification/ALPHA_CAMPAIGN.md §2 — the OCaml half of the reference scenario
---

**Depends on:** FEAT-131.

**Premise (verified 2026-10-03 at `38fe8a2d`):** holds. `ls
examples/pluto/app/payments examples/pluto/app/comms` listed only `charge_svc` and
`notify_worker`; `examples/pluto/app/payments/orders_svc` and
`examples/pluto/app/comms/fulfilment_worker` did not exist, and no handler code for
the scenario was present. The units are declared in `sol.yml` and
`sol/environments.yml`, so the work is the OCaml half of `FEAT-131`'s scenario.

**Related:** FEAT-133 (the TypeScript half), VERIF-027 (local integrated run), FEAT-111, FEAT-120, FEAT-077, FEAT-113, FEAT-094.

Implement the `FEAT-131` scenario in OCaml inside `examples/pluto`, so the campaign has
a reference application that exercises the supported primitives together rather than as
disconnected endpoints. The observable contract is
`internal/qualification/ALPHA_CAMPAIGN.md` §2.

## Scope (the OCaml namespace only)

- `orders_svc` (`-svc`): `POST /orders` performs one Postgres transaction — domain row,
  `send_confirmation` job, `OrderPlaced` outbox intent — and returns `202`; duplicate
  `POST` is idempotent. `GET /orders/{order_id}` reads the order's status back.
- An outbox relay in the service's process publishes `OrderPlaced` to the declared
  topic, in `ord` order, removing a row only after the broker acknowledged it.
- `fulfilment_worker` (`-worker`) consumes `OrderPlaced` and performs its own
  transaction — `fulfilled_orders` row, `release_inventory` job, `OrderFulfilled`
  outbox intent — then acks; its relay publishes `OrderFulfilled`.
- The `sol_jobs` runner hosted by the worker executes both job kinds and records the
  downstream effect the read-back reflects.
- The support for `calls`/NetworkPolicy stays as the workspace declares it.

## Non-goals

- No new framework capability. This uses `sol-svc`, `sol-worker`, `sol-jobs`,
  `sol-outbox` and `sol-obs` as they exist; a missing primitive is a finding, not a
  reason to add one here.
- Do not touch the TypeScript unit tree or its `events/` scope.

## Acceptance criteria

- `dune build` and the workspace's tests pass; the unit tests cover the transaction's
  all-or-nothing property, duplicate-delivery absorption, and the relay's ordering and
  ack-after-publish boundary.
- Against a real broker, Postgres and schema registry (the `VERIF-027` environment):
  one `POST /orders` produces exactly one order row, one job, one `OrderPlaced`, one
  `fulfilled_orders` row, one `OrderFulfilled` and one confirmation effect; the
  read-back reflects the terminal status.
- A deliberately undecodable record on the topic produces the structured decode log,
  the decode-error metric and a DLQ record, and the source offset advances.
- Logs, metrics and traces carry the six identity dimensions for both units, and one
  request's log line, metric series and trace agree.
- Demo/example: this ticket *is* the runnable example; update `examples/pluto/README.md`
  for the units it changes.
- Language parity: state in one line how the TypeScript half (`FEAT-133`) matches the
  behaviour, or record a capability it cannot match yet.

## Progress

**Part A — the offline implementation (landed; the ticket stays READY for the live rows).**

Added the OCaml namespace's storage and job contract (`examples/pluto/lib/orders.ml`,
`orders_jobs.ml`), `orders_svc` (`app/payments/orders_svc/{lib/orders_handler.ml,
bin/main.ml,dune,sol.toml,Dockerfile}`) and `fulfilment_worker`
(`app/comms/fulfilment_worker/{lib/fulfilment_worker.ml,bin/main.ml,dune,sol.toml,
Dockerfile}`), a `test_orders` unit test, and the README section. `orders_svc`
commits the order, the `send_confirmation` job and the `OrderPlaced` intent in one
transaction and relays `OrderPlaced`; `fulfilment_worker` consumes it, commits the
fulfilled row, the `release_inventory` job and the `OrderFulfilled` intent, acks, and
relays `OrderFulfilled`; its `sol_jobs` runner executes both kinds. `send_confirmation`
confirms only once the order is fulfilled, so it retries with backoff rather than
confirming an unfulfilled order (bounded at 20 attempts) and is idempotent when
already confirmed.

Evidence (compiled against the framework under test; CI's
`example-dockerfile-smoke` runs the workspace's own `dune build`, and `test_orders`'s
runtime assertions are `assert`-based):

- `dune build` of the workspace targets → exit 0.
- `test_orders.exe` → exit 0; `test_charges.exe` → exit 0; `test_schemas.exe` → skips
  without `SCHEMA_REGISTRY_URL`.
- `internal/ci/check_no_comments.sh` → 863 files, none commented;
  `internal/ci/check_examples_self_contained.sh` → 39 files, none reference `internal/`.

**Remaining for the ticket to close:** the live rows in the `VERIF-027` environment
(one `POST /orders` producing exactly one row/job/`OrderPlaced`/fulfilled
row/`OrderFulfilled`/confirmation and a terminal read-back; an undecodable record
producing the decode log, metric and DLQ with the offset advancing; the six identity
dimensions agreeing across a request's log line, metric series and trace). These are
the local integrated qualification's rows and are recorded by `VERIF-027`, not
re-derived here.

## Completion notes

Record the exact commands used to produce each observation, so `VERIF-027` can re-run
them and cite them instead of re-deriving them.
