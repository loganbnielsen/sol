---
id: FEAT-116
type: feature
severity: medium
source: BUG-099 (Part B, the event contract)
title: "`sol plan` cannot see contracts that applications declare in code"
---

`sol plan` cannot see contracts that applications declare in code

**Depends on:** None.

## Problem

`sol plan` must show what a deployment will change. Some of what can change is
declared *in application code* rather than in a manifest Sol reads: an event's
partition count and message key now live in the event module's `MESSAGE`
implementation (`partitions`, `key`) because BUG-099 settled that code is the
canonical semantic contract — `key` is executable domain logic, and duplicating
it into TOML would need a synchronisation guard to stay honest.

The CLI's current answer is partial. `Sol_cli_workspace_scan.discover_topics`
reads topic *names* from `events/sol.toml` / `events/<team>/sol.toml`, so the plan
lists topics but can see nothing else about them — and today that list already
disagrees with the code (BUG-107).

This is a general problem, not a Kafka one: as applications express more of their
contract in code, the plan needs a way to inspect it.

## Acceptance criteria

- The chosen mechanism is recorded as a decision, with the alternatives and why
  they were rejected.
- `sol plan` shows a declared event's partition count and key, and names a change
  to either against what is deployed.
- The TypeScript golden path is covered: the same mechanism reports a TS
  application's event contract, or the decision records the deferral and its
  trigger (DEC-022).

## Decision (2026-10-03) — DEC-065: the declarative contract is canonical

Operator decision, recorded in full in `DEC-065`:

- The declarative Sol contract is the canonical source of truth, not application
  code — for the contract properties Sol must reason about (event/schema
  identity, partitions, key semantics).
- Language-specific bindings are generated from the contract into a canonical,
  predictable generated destination that application code imports; developers do
  not independently redeclare generated contract properties.
- Generated bindings are checked in and enforced in CI by regeneration plus a
  drift failure.
- `sol plan` reads the declarative contract directly; it never parses or executes
  application source.
- No separate contract digest unless a concrete provenance gap requires one.
- Reconcile `BUG-099` (whose "code is canonical" premise this reverses) and
  `FEAT-119` (determine whether `contract/run` remains necessary).

This ticket is the implementation unit and is promoted to
`READY_FOR_ENGINEERING`; the declarative surface, generator, checked-in
destination, CI drift check, and `sol plan` read are its scope.


## Reconciliation scope (2026-10-03)

This ticket implements DEC-065 and, as part of it, reconciles two DONE tickets:

- **BUG-099** — its "code is canonical" premise is reversed; the declarative
  contract is canonical and application code consumes generated bindings.
- **FEAT-119** — decide whether the `contract/run` projection remains necessary
  or folds into the generated-bindings mechanism, and record the verdict. File a
  separate ticket only if that verdict needs its own unit.

Record both in the completion notes.

## Completion notes (2026-10-03)

**Premise:** confirmed at `origin/main` `9d1a35f7` before starting — `sol plan`
reported the contract by executing `contract/run --json` (application code was the
source), and `events/<team>/sol.toml` carried only topic names. The stale
decision-required section was removed in this branch; the decision is recorded in
`## Decision` above and in `DEC-065`.

### What landed

- **Declarative surface.** `events/<team>/sol.toml` (and `events/sol.toml`) gain a
  top-level `[[events]]` array: `name`, `topic`, `partitions`, optional `key`, and
  `schema`. `Sol_cli_toml` parses and validates it — the name is an OCaml module
  name, partitions is at least 1, the schema is a JSON object with `properties`, the
  declared `key` must name a property of that schema, names are unique — and
  `discover_topics`/`discover_events` read it. A mis-declared key fails closed.
- **Generator and checked-in destination.** `sol contract generate` writes
  `events/<team>/<team>_contract.ml` from the declaration (one `module <Name> = ...`
  per event, carrying `topic_name`, `schema`, `partitions`, `key_field`), and the
  module includes it: `include Payments_contract.Charged`. The generated file is
  marked `[@@@ocamlformat "disable"]`, so regeneration is byte-stable.
- **CI drift check.** `sol contract generate --check` compares the declaration to the
  checked-in bindings; `internal/ci/check_contract_bindings.sh` runs it over
  `examples/pluto` and the scaffold workspace, and
  `internal/ci/test_contract_bindings.sh` is its mutation suite (a drifted or missing
  binding must fail, naming the file).
- **`sol plan` reads the declaration.** `Sol_cli_contract.plan_report` no longer
  executes `contract/run --json`; it reads `[[events]]` and prints each event's topic,
  partitions, and key. `sol plan prod/aws/us-east-1` in `examples/pluto` reports both
  events without running application code.
- **Scaffold.** `sol new workspace` and `sol new event` emit the declaration, the
  generated binding, and a module that consumes it (`new_event` appends the
  declaration to an existing team manifest and regenerates the team binding).
  `examples/pluto`, the workspace template, and the event template are migrated.
- **Framework.** `Kafka_service.Contract.key_of_field` reads the declared field from
  an encoded message; the event module applies it (`key t =
  Kafka_service.Contract.key_of_field key_field (encode t)`), so the module no longer
  owns key selection.

### BUG-099 reconciliation

BUG-099 Part B settled that `partitions` and `key` are part of the event contract and
placed them in the event module, because in-code key logic cannot be duplicated into
a manifest without a synchronisation guard. DEC-065 reverses that premise for the
contract facts Sol reasons about: the declaration is canonical, the binding is
generated, and the key is a declared field rather than executable logic. Behaviour
(`type t`, `encode`, `decode`) stays in code. BUG-099's executable-only concerns are
therefore not reopened; its "code is canonical" statement is superseded, and this
note is the record of that.

### FEAT-119 verdict — `contract/run` is kept, its projection is superseded for planning

`contract/run --check` / `--apply` (the schema-registry reconciliation the deployment
Job runs in the destination) remains: it is the language-toolchain boundary, the same
reason FEAT-119 introduced it. Its `--json` projection is **no longer used by
`sol plan`**, because the plan reads the declaration directly (DEC-065 §5). The
projection is not deleted (it remains a documented capability of `contract/run`);
the OCaml projection and the generated module derive from the same schema, so no
drift is possible. Verdict: **keep `contract/run`; fold the planning read into the
declaration.** No separate follow-up unit is needed for that.

### TypeScript parity (DEC-022)

Deferred with a trigger, recorded in the decision and filed as **FEAT-129**: a
TypeScript scope still hand-declares its contract in
`examples/pluto/app/demo_ts/contract/src/contracts.ts`. Trigger: the TypeScript golden
path next needs qualification against the declarative contract (FEAT-102 or a TS
golden-path change), or `@sol-fab/kafka` publishes a shape the generator can target.
The mechanism landed here is language-neutral in the declaration and one binding per
language, so the TS binding is a generator addition, not a redesign.

### Checks

`dune build @all` clean (includes `examples/pluto`); `dune test cli/test` green (new:
declaration parsing/validation, generator render/path, discovery, drift detection,
scaffold topic-from-declaration); `framework/ocaml/kafka-eio-service` tests green;
`internal/ci/run_fast_checks.sh` green after `guard_env.txt` classifies the guard's
`CONTRACT_BINDINGS_CHECKOUT` input. `sol contract generate --check` clean for
`examples/pluto` and the workspace template; `sol new workspace`/`sol new event`
exercised end to end on a scratch workspace.

### Acceptance mapping

| Criterion | Evidence |
|---|---|
| The mechanism is recorded with alternatives and why rejected | `DEC-065` (alternatives section) |
| `sol plan` shows a declared event's partitions and key, without parsing or running code | `plan_report` reads `[[events]]`; verified on `examples/pluto` |
| TS golden path covered, or deferral + trigger recorded | FEAT-129; recorded above and in `DEC-065` |

**Demo/example coverage.** `examples/pluto` declares both events in `sol.toml`, the
bindings are generated and checked in, its modules consume them, and `sol plan` reports
them — the declare → regenerate → plan path end to end. The scaffold emits the same
shape.

**Follow-up (2026-10-03, operator review).** The plan shows the declared partition
count and key; it does not yet diff them against a *deployed* contract, because the
release record does not carry the contract. The ticket's own criterion — "names a
change to either against what is deployed" — is therefore **not met**; DEC-065's
acceptance ("`sol plan` reading the declaration") is. The remainder is not a rename
of this ticket's gap but a release-metadata unit and is filed as **FEAT-130**
(record the deployed contract and render `observed → desired`), which also carries the
unresolved decision about where the observed half comes from. The deploy-time
partition guard still rejects a reduction against the live topic. This ticket is DONE
for the source-of-truth half only; the plan story is finished when FEAT-130 lands.

**TypeScript follow-up (2026-10-03, operator review).** The deferral recorded below
was revisited: the campaign is the OCaml *and* TypeScript reference-app qualification,
so FEAT-129's trigger is met. It was promoted to `READY_FOR_ENGINEERING/` as a pre-S5
enabler.
