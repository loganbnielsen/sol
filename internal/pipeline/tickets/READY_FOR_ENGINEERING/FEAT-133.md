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

## Completion notes

Record the exact commands used for each observation, and any capability the two
languages still express differently, so `VERIF-027` can compare the rows directly.
