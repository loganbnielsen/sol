---
id: FEAT-129
type: feature
severity: medium
source: DEC-065 (the declarative contract is canonical) — the TypeScript half; DEC-022
title: "Generate TypeScript contract bindings from the declarative event contract"
---

Generate TypeScript contract bindings from the declarative event contract

**Depends on:** None.

## Problem

DEC-065 made `events/<team>/sol.toml` canonical for the contract facts Sol must
reason about — event/schema identity, partitions, and key semantics — and FEAT-116
generates the OCaml binding from it (`sol contract generate` →
`events/<team>/<team>_contract.ml`), checks it in, and drift-checks it in CI.

A TypeScript scope is not covered by that generator. In
`examples/pluto/app/demo_ts`, the contract is still hand-declared in
`contract/src/contracts.ts` (`TopicContract` values carrying `name`, `schema`,
`partitions`, and a `key` function), so a TypeScript application's contract is not
produced from the declarative source, `sol contract generate --check` has nothing to
check for it, and `sol plan` cannot report its events. The two languages drift.

This is the deferral DEC-065 permits: the decision requires the same
generated-bindings mechanism for the TypeScript golden path, or the deferral and its
trigger recorded (DEC-022). FEAT-116 records the deferral; this ticket carries the
obligation.

## Remediation

Extend the generator to TypeScript scopes, from the same `[[events]]` declaration:

- Emit a TypeScript binding into a canonical, predictable destination that the
  workspace imports, checked in and covered by `sol contract generate --check` — the
  same contract the OCaml binding is generated from, so the two cannot disagree.
- Express the declared key as a field-based extractor (`key_field`), so the generated
  TypeScript contract reads the declared field of the encoded object rather than a
  hand-written key function; `@sol-fab/kafka`'s `TopicContract` (external) either
  accepts that shape or the workspace adapts it.
- Rewrite `examples/pluto/app/demo_ts/contract/src/contracts.ts` to be (or import) the
  generated binding, keeping `order_svc`'s import of `@demo-ts/contract`, and update
  the capability matrix row (FEAT-080).

## Disposition (2026-10-03) — promoted; required before S5

Operator review of the FEAT-116 landing: the campaign is the OCaml **and**
TypeScript reference-app qualification, so this deferral's trigger fires now rather
than after alpha. A TypeScript reference app that is meant to demonstrate the
canonical-contract architecture cannot keep hand-declaring its contract while the
OCaml half is generated from `[[events]]`. Promoted from `BACKLOG/` to
`READY_FOR_ENGINEERING/`; this is a pre-S5 enabler, not post-alpha cleanup.

The stated trigger — the TypeScript golden path needing qualification against the
declarative contract (FEAT-102 and the reference-app campaign) — is met. The
second condition (an `@sol-fab/kafka` shape the generator can target) is a
convenience, not a prerequisite: the workspace can adapt the generated contract.

**Settle first: where a TypeScript scope declares its events.** `events/<team>/` is
today an OCaml dune library and the generated destination is `<team>_contract.ml`.
A TypeScript scope needs an equivalent declaration location, a canonical generated
destination (the hand-written home is `examples/pluto/app/demo_ts/contract/src/`),
and the workspace must resolve a scope's language so the generator picks the binding.
Record that choice in this ticket's completion notes; it is the one
generated-bindings decision DEC-065 left open.

## Acceptance criteria

- A TypeScript scope can declare its events in `events/<team>/sol.toml`, generate a
  binding with `sol contract generate`, and have `sol contract generate --check` fail
  when the checked-in binding drifts.
- The generated TypeScript contract carries the declared topic, partitions, schema,
  and key field; the application does not redeclare them.
- `sol plan` reports the TypeScript scope's declared events, as it does the OCaml
  scope's.
- `examples/pluto/app/demo_ts` compiles and its contract is the generated binding.

**Demo/example coverage:** this ticket *is* the TypeScript example update.

## TypeScript parity

This ticket is the TypeScript half of DEC-065; closing it removes the only
language-parity deferral that decision recorded.

## Completion notes (2026-10-03)

**Settled decision — the declaration is language-neutral; destinations are derived.**
`events/<team>/sol.toml` stays the single canonical declaration for every language: a
top-level `[contract] language` selects the binding and **no filesystem path is
declared**. The generator derives the destination from the language, so the OCaml-first
layout is not baked in:

- `ocaml` → `events/<team>/<team>_contract.ml` (the dune library that consumes it).
- `typescript` → `app/<team>/contract/src/<team>_contract.ts` (the scope's contract
  package — where a TypeScript app already imports its contract from).

`[contract] language` is required whenever a manifest declares `[[events]]`; a manifest
that declares a contract and no language fails closed rather than defaulting to OCaml.
The event team is the app scope (`events/payments` ↔ `app/payments`), so the TypeScript
destination is derived, not declared.

### What landed

- **Generator.** `Sol_cli_contract_gen.generated_path ~dir ~language` derives the
  destination; `render ~language` emits either the OCaml module or a TypeScript module
  exporting an `EventContractSpec` per event plus a `generatedContract<T>` factory whose
  `key` reads the declared `keyField` (so the app never hand-writes the key function).
- **Discovery.** `Sol_cli_workspace_scan.discover_contracts` returns `(dir, language,
  events)`; `discover_events` and `sol plan` read across both languages, so
  `sol plan prod/aws/us-east-1` in `examples/pluto` reports the TypeScript
  `OrderPlaced`/`OrderFulfilled` beside the OCaml events.
- **Drift.** `sol contract generate --check` covers both languages;
  `internal/ci/check_contract_bindings.sh` runs it over `examples/pluto` and the
  scaffold, and `test_contract_bindings.sh` mutates the OCaml *and* TypeScript bindings,
  requiring the failure to name the drifted file.
- **Reference app.** `examples/pluto/events/demo_ts/sol.toml` declares the TypeScript
  events; `app/demo_ts/contract/src/contracts.ts` is now the value types plus two
  `generatedContract<T>(…Spec)` bindings; `fulfillment_worker` takes its topic and
  partition count from `ORDER_PLACED` instead of a copied literal and an `ORDERS_TOPIC`
  env fallback (nothing deployed or documented set that variable).
- **Scaffold.** The workspace event template and `sol new event` carry
  `[contract] language = "ocaml"`; appending a second event appends only the `[[events]]`
  section, so the language is declared once.
- **Docs.** The tutorial's event-contract section covers both languages, the
  conventions table gains a "Contract declaration → generated binding" row, and the
  TypeScript capability matrix gains the same row.

### Checks

`dune build @all` clean. `dune test cli/test` green apart from two pre-existing
environment failures (`existing_files: scaffold actually compiles`, `bare fn library
compiles`) that require the framework packages installed from opam — both fail
identically on unmodified `origin/main` in this switch. `internal/ci/run_fast_checks.sh`
green (the `ci-unit` class passes). `internal/ci/check_contract_bindings.sh` and its
mutation suite green. The TypeScript demo was run for real: `npm ci` then
`npm run build -w order-svc -w fulfillment-worker` typechecks the generated binding and
both services, `npm run contract -- --json` emits the projection from the generated
contract, and `npm test` runs (5 tests skip without local Kafka/Postgres, as before).

### Acceptance mapping

| Criterion | Evidence |
|---|---|
| A TypeScript scope declares its events in `events/<team>/sol.toml`, generates, and `--check` catches drift | `examples/pluto/events/demo_ts/sol.toml`; `test_contract.ml` TypeScript generate/drift test; guard + mutation suite |
| The generated TypeScript carries topic, partitions, schema, and key field; the app does not redeclare them | `app/demo_ts/contract/src/demo_ts_contract.ts`; `contracts.ts` supplies only value types |
| `sol plan` reports the TypeScript scope's events | verified: `sol plan prod/aws/us-east-1` lists `events/demo_ts` OrderPlaced/OrderFulfilled |
| `examples/pluto/app/demo_ts` compiles, its contract is the generated binding | TS build/typecheck passed locally |

**Demo/example coverage:** `examples/pluto` — the TypeScript reference app now declares
its contract in `sol.toml` and consumes the generated binding.

**TypeScript parity:** this is the TypeScript half of DEC-065; the language-parity
deferral it recorded is now closed.
