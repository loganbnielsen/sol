---
id: FEAT-132
type: feature
severity: high
title: "OCaml reference application: 'Pluto orders' end to end (request -> tx -> outbox -> Kafka -> worker -> job -> read-back)"
source: internal/qualification/ALPHA_CAMPAIGN.md §2 — the OCaml half of the reference scenario
---

**Depends on:** FEAT-131.

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

## Completion notes

Record the exact commands used to produce each observation, so `VERIF-027` can re-run
them and cite them instead of re-deriving them.
