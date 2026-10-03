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

## Trigger

Fire when either: the TypeScript golden path next needs qualification against the
declarative contract (the TS production-profile work in FEAT-102, or any change to
the TS golden path), or `@sol-fab/kafka` publishes a contract shape the generator can
target. Until then the deferral stands and `examples/pluto`'s TS contract is the one
hand-declared contract in the reference app.

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
