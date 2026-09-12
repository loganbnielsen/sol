---
id: FEAT-064
type: feature
severity: medium
source: FEAT-061 part 1, 2026-09-11 — the vocabulary landed on a branch; the consumer did not
---

**Depends on:** FEAT-061.

Wire the scope vocabulary into the commands that select work, and record the resolved scope in the plan.

## What already exists

`Sol_cli_deployment_scope` landed on branch `FEAT-061/scope` (commit `4bd024ae`), verified by ten unit tests: `parse_request` (`domain`, `domain/unit`, or absent for the workspace), `select_named` and `select` (resolution against discovery, failing closed with what exists), `named_of_spec`, `kind_of_primitive`, and `to_string`. It is not yet consumed by any command, which is the whole of this ticket.

The design decision that shaped it is recorded on FEAT-061: **scope is a named unit**, with the positional path argument kept as the explicit escape hatch. A service is spelled `domain/service`, matching `sol open`.

## What remains

**1. A consumer, and the plumbing needs care.** The attempt to add `--scope` to `sol check` was reverted, not because the approach was wrong but because the nested `match` in `cmd_check.ml`'s `run` was thrashing on paren balance. The shape that reads well: bind `request` and `services` with separate `let`s (each `match` handling its own failure and exiting), then a single parenthesised `match` on `select`. Do not nest parens three deep.

**2. Replace `filter_path` in the deploy path.** `sol up` and `Sol_cli_factory.run` thread a path prefix; a resolved scope should select the units instead, with the path argument retained as the escape hatch. This is where criterion 4's fail-closed behaviour matters most: an unmatched selection currently deploys nothing, quietly.

**3. Record the scope with the deployment** and show it in `--emit-plan-to` output, so "what was deployed" has an answer that survives the command (FEAT-061's criterion 3). The plan already carries per-service detail, so this is a field plus its JSON, not a new shape.

**4. The independence tests** (FEAT-061's criterion 2) — selecting a scope must not affect the resolved destination and vice versa — which cannot be written meaningfully until FEAT-063 threads the destination through. Do them together or in that order.

**5. The projection onto `sol open`'s addressing**, documented where both types are visible: service → `domain/service`, worker/function → their `domain/service` naming, workspace → workspace. `open`'s scope has no worker or function case because telemetry naming collapses them, which is exactly why these are two types with a projection rather than one type.

## Acceptance criteria

- `sol check --scope payments/charge_svc` checks that unit, and `--scope logistics` fails closed naming what exists.
- The path argument keeps working unchanged, and the two are separate arguments rather than one that guesses.
- The deploy path selects by scope, and an unmatched scope fails closed before anything is applied.
- The resolved scope appears in the emitted plan.
- The projection onto `sol open`'s scope is implemented and documented where both types are visible.

## Notes

Split from FEAT-061 rather than left half-built: the vocabulary is complete and tested, and this is the consumer work. It is deliberately not a "part 2" of an unfinished branch — the branch is ready to merge as the vocabulary, and this ticket takes it from there.
