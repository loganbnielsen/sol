---
id: FEAT-133
type: feature
severity: high
title: "TypeScript reference application: 'Pluto orders' end to end, behaviourally equivalent to the OCaml half"
source: internal/qualification/ALPHA_CAMPAIGN.md §2 — the TypeScript half of the reference scenario
---

**Depends on:** FEAT-131.

**Related:** FEAT-132 (the OCaml half), VERIF-027, FEAT-118, FEAT-124, FEAT-125, FEAT-102, DEC-022.

Implement the `FEAT-131` scenario in TypeScript inside `examples/pluto/app/demo_ts`, so
the campaign can compare the two languages' externally observable behaviour rather
than reasoning about it. The existing `order_svc`/`fulfillment_worker` pair is the
starting point; bring it to the full scenario contract and to behavioural equivalence
with `FEAT-132`. The observable contract is
`internal/qualification/ALPHA_CAMPAIGN.md` §2.

## Scope (the TypeScript namespace only)

- `orders_svc`: `POST /orders` performs the transaction — domain row, job, `OrderPlaced`
  outbox intent — via `@sol-fab/jobs` and `@sol-fab/outbox`, and returns `202`;
  `GET /orders/{order_id}` reads the status back.
- `fulfilment_worker`: consume `OrderPlaced`, transaction (fulfilled row, job,
  `OrderFulfilled` intent), ack, relay.
- The job runner executes both kinds and records the downstream effect.
- Bring the scenario's schema under migrations (`FEAT-131`) rather than the current
  application-time `CREATE TABLE IF NOT EXISTS`, so the migration gate and checksum
  rows cover the TS namespace too.
- Preserve the existing idempotency guarantees (`BUG-112` shape) and the DLQ behaviour
  the scenario contract requires.

## Non-goals

- No new `@sol-fab/*` package. If a capability the scenario needs is missing from a
  published package, file it against `sol-typescript` and record the row as blocked;
  do not vendor a replacement into the example.
- Do not touch the OCaml unit tree or its `events/` scope.
- Not the production-profile qualification (`FEAT-102`); this is the local/reference
  demonstration.

## Acceptance criteria

- `npm ci` + `npm test` pass, including the duplicate-delivery and outbox-boundary
  tests, extended to the full scenario.
- Against a real broker, Postgres and schema registry (the `VERIF-027` environment), the
  TS namespace produces exactly the same observable sequence as the OCaml namespace:
  one order row, one job, one `OrderPlaced`, one fulfilled row, one `OrderFulfilled`,
  one confirmation effect, and a read-back of the terminal status.
- Logs, metrics and traces carry the six identity dimensions, and one request's three
  signals agree — behaviourally equal to `FEAT-132`.
- Demo/example: update `examples/pluto/app/demo_ts/README.md` and the workspace README.
- Language parity: state any row `FEAT-132` satisfies that the TS half cannot, with the
  tracking ticket — silence is not a verdict.

## Completion notes (2026-10-03)

Premise verified at `38fe8a2d` (`FEAT-131` merged): the TS pair produced
`OrderPlaced` straight from the HTTP handler, wrote no acceptance row or job, had
no read-back, and provisioned its tables with `CREATE TABLE IF NOT EXISTS` in
`db.ts`. Every one of those was still the work.

### What landed

- `order_svc` accepts transactionally: `POST /orders` commits `orders_ts` (row,
  `ON CONFLICT`), the `send_confirmation` job (dedupe `order_id`) and the
  `order_placed` outbox intent (`ord = 1`) in one `withTransaction`, then answers
  `202 {order_id, status}`; duplicates are absorbed and still answer `202`.
  `GET /orders/{order_id}` reads `accepted`/`fulfilled`/`confirmed` back from the
  acceptance row's `fulfilled_at`/`confirmed_at`, or `404`.
- `order_svc` hosts its own outbox relay; `fulfillment_worker`'s transaction now
  also marks the acceptance row `fulfilled`, enqueues `release_inventory`, and its
  runner writes the confirmation effect (`order_confirmations_ts` plus
  `confirmed_at`), so the read-back reaches `confirmed`.
- The units create no tables: `orders_ts`, `fulfilled_orders_ts`,
  `order_confirmations_ts`, `sol_jobs` and `sol_outbox` are the workspace
  migrations (`0002`, `0003`, `0006`), and `0007_orders_ts_traceparent.sql` adds
  the accepted order's W3C trace context. The golden-path smoke now runs
  `sol local migrate` before `sol up`; the offline suite applies the same
  migration files itself (`test/migrations.ts`), so a table missing from a
  migration fails the tests.
- Two design points the diagram left implicit, resolved in the app (not in a
  package): the two relays share one `sol_outbox`, so each refuses a
  `publication.kind` it does not own, and `OrderFulfilled` uses `ord = 2` —
  a per-key ordering token is the caller's to assign, and two producers must not
  reuse one. `OrderPlaced` stays `ord = 1`.
- Trace continuity (G3) survives the relay: the handler stores `traceparentOf(span)`
  on the acceptance row, and the relay replays it as the record's `traceparent`
  header, so one trace still holds `receive_order`, the Kafka boundary and
  `fulfill_order`.

### Commands and observations

```sh
docker run -d --rm -p 55432:5432 -e POSTGRES_PASSWORD=postgres postgres:16
cd examples/pluto/app/demo_ts
npm ci
POSTGRES_URL=postgres://postgres:postgres@localhost:55432/postgres npm run build -w order-svc -w fulfillment-worker
POSTGRES_URL=postgres://postgres:postgres@localhost:55432/postgres npm test
# tests 10 / pass 10 / fail 0
```

`test/placement.test.ts` (new) covers the service transaction, duplicate
absorption and the rollback; `test/scenario.test.ts` (new) runs the whole path
against one Postgres — accept → `accepted`, relay context on the row, worker
transaction → `fulfilled`, both job kinds run → `confirmed`, one confirmation
effect; `test/delivery.test.ts` and `test/outbox.test.ts` keep their
duplicate-delivery and relay-boundary assertions on the migration-owned schema.

### Demo and language parity

Demo/example: `examples/pluto/app/demo_ts/README.md` and `examples/pluto/README.md`
updated (the transaction, the read-back, the migration ownership, the relay
ownership, the trace context, and `sol local migrate` in the walkthrough).

Language parity: no capability gap found. The TS half satisfies B1–B6, C1–C3/C5/C6
and G3 for its namespace; the two halves share only the event declarations. Two
places where the two implementations may differ observably and `VERIF-027` should
compare rather than assume: (1) the OCaml `orders_svc` relays `OrderPlaced` too,
so it needs the same disjoint-`ord` and kind-ownership policy against the shared
`sol_outbox` — the diagram assigns `ord = 1` to both units' intents, which cannot
both hold under `sol_outbox_key_ord_idx`; (2) the OCaml half must carry the
caller's trace context out-of-band to keep G3 across its relay — this half stores
it on the acceptance row (`0007`). Recorded here rather than as a new ticket
because both are app-level policy the published `@sol-fab/outbox` API supports;
the ergonomic gap (a relay cannot scope itself to its own kinds, so the other
unit's rows surface as retryable failures until their owner publishes them) is
worth a `sol-typescript` issue and is called out in the README.
