---
id: FEAT-131
type: feature
severity: high
title: "Reference application contract: one language-neutral 'Pluto orders' scenario declared once"
source: internal/qualification/ALPHA_CAMPAIGN.md §2 — the scenario the alpha campaign qualifies in both languages
---

**Depends on:** None.

**Related:** FEAT-132, FEAT-133, VERIF-027, FEAT-116, FEAT-129, FEAT-111, FEAT-120, FEAT-124, DEC-022.

**Premise (verified 2026-10-03 at `ed3f041f`):** holds. `git grep -n 'OrderPlaced'
ed3f041f -- examples/pluto/events` matched only `events/demo_ts/sol.toml` (the
TypeScript binding — no OCaml scope); `git ls-tree --name-only
ed3f041f:examples/pluto/db/migrations` listed `0001`–`0004` (no scenario tables);
`git grep -n 'orders_svc' ed3f041f -- examples/pluto/sol.yml` matched nothing.

The alpha campaign qualifies one realistic backend workflow implemented independently
in OCaml and TypeScript, with equivalent externally observable behaviour. This ticket
lands the *language-neutral contract* both implementations build against, so the two
per-language streams can work in disjoint directories without contending for the
workspace's shared files.

The scenario and its observable contract are defined in
`internal/qualification/ALPHA_CAMPAIGN.md` §2. This ticket makes that contract real in
`examples/pluto`.

## Scope

- Declare both scenario units in `examples/pluto/sol.yml` with their `language` and
  `calls`, and their targets/domains in `sol/environments.yml`, so `sol check` and the
  profile preflight see the whole workspace.
- Add the database migrations both implementations share the shape of: the domain
  tables for the OCaml and TS namespaces, plus the `sol_jobs` and `sol_outbox` DDL
  where the existing migrations do not already provide it.
- Declare the two events (`OrderPlaced`, `OrderFulfilled`) once per language binding
  scope under `events/<scope>/sol.toml`, with the same schema, partition count and
  message key in both, and generate and check in both bindings
  (`sol contract generate`). The two declarations are the two language bindings of
  one event contract, and a test asserts they are schema-identical.
- State the HTTP and event contract in one place the per-language streams both read
  (the workspace README), including the failure semantics: duplicate delivery,
  decode-error DLQ, and the `Dead_letter` fail-closed case.

## Non-goals

- No application logic: the units are declared and their contract is checked in; the
  handlers are `FEAT-132` and `FEAT-133`.
- No new framework primitive or `sol.toml` field. This is a workspace example using
  capabilities that already exist.

## Acceptance criteria

- `sol check` passes on the workspace with both languages declared, and the production
  profile preflight reports TypeScript exactly as it does today (staged, not silently
  admitted) rather than being weakened.
- The two event declarations carry the same schema, partitions and key; a test fails
  if either drifts, and `sol contract generate --check` is green for both bindings.
- The database DDL exists as migrations (not only as application-time
  `CREATE TABLE IF NOT EXISTS`), so the deploy migration gate and the checksum row
  (`FEAT-094`) cover the scenario's schema.
- Demo/example: this ticket *is* the example's contract; the workspace README documents
  the scenario end to end and the per-language streams reference it.
- Language parity: this ticket is the parity contract; note anything a language cannot
  express.

## Completion notes (2026-10-03)

### What landed

- **One semantic contract, one direction.** `events/orders/sol.toml` is the
  scenario's canonical event declaration (`[contract] language = "ocaml"`,
  `OrderPlaced`/`OrderFulfilled`, schema, `partitions = 3`, `key = "order_id"`),
  and `events/orders/orders_contract.ml` is its generated OCaml binding.
  `events/demo_ts/sol.toml` is the TypeScript **projection** of it: the same two
  events with the same schema/partitions/key and the TypeScript namespace topics.
  The projection is not a second authority — `internal/ci/check_scenario_contract.py`
  requires every projection event to reproduce the canonical name, schema,
  partitions and key, forbids a projection from adding or dropping an event, and
  requires the two scopes' topics to be disjoint. `internal/ci/test_scenario_contract.py`
  mutates each of those and requires the guard to fail naming the file. That
  direction is what the repository representation can hold: a Sol scope binds one
  language and an event carries one topic, so the two deployments need two
  declarations, and the guard keeps the second a derived projection rather than a
  co-equal source. The `sol.toml` headers and the workspace README state it.
- **OCaml event modules and projection.** `events/orders/order_placed.ml` and
  `order_fulfilled.ml` carry the value type, codec and `key`, `include`ing the
  generated binding (`pluto_orders_events`); `contract/contract.ml` adds both to
  the OCaml projection program so `sol up`/`sol deploy` reconcile their registry
  subjects.
- **Migrations.** `db/migrations/0005_orders.sql` (+ `.down.sql`) and
  `0006_orders_ts.sql` (+ `.down.sql`), each opening with
  `-- sol:disposition expand`. `sol_jobs`/`sol_outbox` are already `0002`/`0003`,
  so no shared DDL was added. The TypeScript demo's application-time
  `CREATE TABLE IF NOT EXISTS` still runs against the same shapes; removing it is
  `FEAT-133`.
- **Unit declarations.** `sol.yml` declares `orders_svc` (http,
  `app/payments/orders_svc`) and `fulfilment_worker` (worker,
  `app/comms/fulfilment_worker`), both `language: ocaml`, `uses: [app_db, events]`;
  `sol/environments.yml` adds their prod scale and dev omit entries. There is no
  `calls` member: `sol.yml` carries no `calls` key (`Sol_cli_config.decode_service`
  refuses unknown keys) and this scenario has no east-west HTTP call, so "language
  and calls" is the language declaration here plus each unit's own `[service]
  calls` when `FEAT-132` adds its `sol.toml`. The directories are `FEAT-132`'s
  (the campaign's T2 boundary), so the workspace declares the units before their
  directories exist; `sol check`/`sol plan` read the declaration now.
- **README.** `examples/pluto/README.md` gains the scenario section: the
  two-namespace table, the workflow, the observable contract (HTTP, events,
  atomicity, duplicate delivery, decode DLQ, fail-closed `Dead_letter`, identity),
  the one-source-of-truth rule with the two `sol contract` commands, and the
  scenario's current state.

### Names FEAT-132 / FEAT-133 / VERIF-027 can consume

| | OCaml namespace | TypeScript namespace |
|---|---|---|
| units | `orders_svc` (http, domain `payments`), `fulfilment_worker` (worker, domain `comms`) | `order_svc` (http), `fulfillment_worker` (worker) |
| events scope | `events/orders` (canonical) | `events/demo_ts` (projection) |
| `OrderPlaced` topic | `orders.v1` | `sol-demo-ts-orders` |
| `OrderFulfilled` topic | `orders-fulfilled.v1` | `sol-demo-ts-fulfilled` |
| partitions / key | 3 / `order_id` | 3 / `order_id` |
| registry subjects | `orders.v1-value`, `orders-fulfilled.v1-value` | `sol-demo-ts-orders-value`, `sol-demo-ts-fulfilled-value` |
| tables | `orders`, `fulfilled_orders`, `order_confirmations` | `orders_ts`, `fulfilled_orders_ts`, `order_confirmations_ts` |
| job kinds | `send_confirmation`, `release_inventory` | `send_confirmation`, `release_inventory` |
| job workspace | `pluto.orders` | `pluto.demo_ts` |
| shared tables | `sol_jobs`, `sol_outbox` (`0002`, `0003`) | same |

Both events, both languages, carry this schema byte-for-byte:

```
{"type":"object","properties":{"order_id":{"type":"string"},"item":{"type":"string"},"quantity":{"type":"integer"},"correlation_id":{"type":"string"}},"required":["order_id","item","quantity","correlation_id"]}
```

### Checks

- `sol check` → `sol check: ok`. `sol plan prod/aws/us-east-1` lists `orders_svc`
  and `fulfilment_worker` with `scale: 1..2`, and both `events/orders` events
  beside the `events/demo_ts` ones.
- `sol deploy pilot/aws/us-east-1 --dry-run` still reports TypeScript staged:
  `service "order_svc" declares language typescript, which
  production-single-region/v1 does not qualify` — the preflight is not weakened.
- `sol contract generate --check` green for both bindings;
  `internal/ci/check_contract_bindings.sh` and `test_contract_bindings.sh` green;
  `internal/ci/check_scenario_contract.py` and `test_scenario_contract.py` green
  (eight mutations, each failing the guard naming the file);
  `dune build @all`, `internal/ci/check_ocamlformat.sh --all`,
  `internal/ci/check_no_comments.sh` and `check_examples_self_contained.sh` green.
- `internal/ci/run_fast_checks.sh` green: build, `@ci-unit`, `@ci-lifecycle`,
  ticket validation/transitions, `verify always` 0/9 and `verify static` 0/104 —
  the 104 include the new `check_scenario_contract.py` and its mutation suite.

### Acceptance mapping

| Criterion | Evidence |
|---|---|
| `sol check` passes with both languages declared; the profile preflight still reports TypeScript staged | commands above |
| Same schema/partitions/key in both declarations; a test fails on drift; `--check` green | `check_scenario_contract.py` + seven-mutation suite; `sol contract generate --check` |
| The DDL exists as migrations, covered by the deploy gate and checksum row | `0005`/`0006` with `.down.sql` and `sol:disposition` headers |
| README documents the scenario end to end | `examples/pluto/README.md` § *The reference scenario: Pluto orders* |
| Language parity stated | below |

**Demo/example coverage:** this ticket *is* the example contract. The runnable
demonstration is `examples/pluto` (the README plus `sol check`, `sol plan`,
`sol contract generate --check`); the behaviour demo is `FEAT-132`/`FEAT-133`.

**Language parity (DEC-022):** no language-parity impact beyond the ticket's own
purpose — the declaration is language-neutral, both languages consume a generated
binding from it, and neither needs a capability the other cannot express. The
runtime parity rows stay `FEAT-132`/`FEAT-133`.

### Follow-ups and limitations

- The campaign matrix row `B7` (cross-language contract equivalence) can move to
  its offline evidence class: the two scopes now declare the same events, both
  bindings generate and drift-check, and the projection guard holds them
  together. `ALPHA_CAMPAIGN.md` is the campaign lead's artifact, so the row is not
  flipped here.
- `orders_svc`/`fulfilment_worker` have no directory until `FEAT-132`. `sol check`
  reports `ok` and `sol plan` renders both from the declaration; `sol check` does
  not diagnose a `sol.yml` service whose directory is absent, so that gap is
  filed as `BUG-131` (with its reproduction) rather than worked around here. The
  `sol.yml` language declaration is in place.
- `0001`–`0004` carry no `sol:disposition` header (only `0001` has a `.down.sql`).
  That predates this ticket; editing an applied migration would break `FEAT-094`'s
  checksum, so it is left alone. The new migrations carry the header and their
  downs.
- The projection guard reads TOML through the pinned `tomli` backport, not the
  stdlib `tomllib`: the `test` job runs on `ubuntu-22.04` (Python 3.10), which has
  no `tomllib`. `tomli==2.2.1` is pinned in `internal/ci/requirements.txt` and
  probed by `internal/tooling/scripts/prepare-guard-tools.sh`.
