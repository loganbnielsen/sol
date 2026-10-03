---
id: FEAT-131
type: feature
severity: high
title: "Reference application contract: one language-neutral 'Pluto orders' scenario declared once"
source: internal/qualification/ALPHA_CAMPAIGN.md §2 — the scenario the alpha campaign qualifies in both languages
---

**Depends on:** None.

**Related:** FEAT-132, FEAT-133, VERIF-027, FEAT-116, FEAT-129, FEAT-111, FEAT-120, FEAT-124, DEC-022.

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

## Completion notes

Record the event/topic/table/job names each language uses, so `FEAT-132`, `FEAT-133`
and `VERIF-027` can reference them without re-reading the tree.
