---
id: FEAT-084
type: feature
severity: medium
title: TypeScript unit scaffolding - a supported path from sol new to a TS app
source: FEAT-082 golden-path walk 2026-09-15 - the walk's first and hardest gap
---

**Depends on:** DEC-022 (language-neutral platform).

**Related:** FEAT-082 (umbrella), FEAT-033 (whose explicit non-goal this was),
DEC-023.

## Evidence (real run, 2026-09-15, CLI at e0678f71)

```text
$ sol new my-app --language typescript
sol: unknown command my-app. Must be one of event, fn, svc, worker or workspace

$ sol new --help
COMMANDS: event, fn, svc, worker, workspace        # no --language on any of them

$ grep -rn -iE "typescript|--language" cli/sol/
(no matches)

$ sol new workspace walkapp
Done. 28 files generated.
  cd walkapp
  eval $(opam env) && dune build   # verify the scaffold compiles
```

→ the scaffold is entirely OCaml (`dune-project`, `.ml`, `.ocamlformat`); zero
`.ts` files.

## What this is

FEAT-082's journey begins with `sol new my-app --language typescript`. That
command does not exist and there is no `--language` flag anywhere: the CLI has
no language concept at all. A TypeScript developer cannot start from Sol — they
must hand-construct a Sol unit.

## What is *not* the gap (which keeps the fix small)

Language-neutrality already holds at the **declaration** layer:

- `examples/pluto/app/demo_ts/{order_svc,fulfillment_worker}/sol.toml` are
  ordinary Sol units, identical in shape to the OCaml ones (all-optional
  template).
- `sol check` passes in `examples/pluto` with those TS units present, and the
  toml schema has no language field.

So Sol does not need a language-aware manifest. What is missing is a
**supported path from `sol new` to a TypeScript Sol application** — that is the
framing this ticket owns.

## Where language selection belongs (do not assume workspace-level)

The walk falsified an assumption we had been carrying: that Sol had a
language-selecting *workspace* generator merely lacking a TS implementation. It
does not. The CLI thinks in **unit kinds**
(`sol new workspace | svc | worker | fn | event`), and the declaration layer has
no language concept at all.

That matters, because DEC-022's clause 7 makes language a property of a **unit's
implementation**, not of a workspace: a workspace may mix TypeScript and OCaml
units, and `sol.toml` must stay language-free. So the natural boundary for
language selection is *unit creation*:

```text
sol new workspace my-app
cd my-app
sol new svc payments/api --language typescript
sol new worker payments/ledger --language ocaml
sol new fn payments/reconcile --language typescript
```

versus the workspace-level form (`sol new workspace my-app --language
typescript`), which encodes the ownership boundary DEC-022 explicitly rejects.

**This ticket does not decide which UX shape ships.** That is DX work belonging
to FEAT-082's walk, informed by what a working TypeScript unit actually needs;
an ergonomic default (e.g. inheriting the last-used language) is also open. The
requirement is that the intent is met, not a particular flag position.

## Do not design the scaffold before the walk finishes

`demo_ts` is a *working*, hand-built TypeScript Sol application. Run it end to
end (`sol local infra up` → `sol up` → a real TS svc + worker →
health/metrics/traces/logs) and derive the scaffold's required contents from
what that run proves is needed. Designing the scaffold first discovers its gaps
last.

## Non-goals

- Not a language field in the manifest (the demo proves none is needed).
- Not a workspace-level language.
- Not publishing the packages (DEC-023).
- Not the runtime-glue decision (FEAT-082's walk and its child tickets).

## Acceptance criteria

- A fresh developer can get from `sol new` to a running TypeScript Sol unit
  (service / worker / function) using only documented commands; the exact UX
  shape is FEAT-082's DX call.
- Language is selected at unit creation and is **not** persisted into the unit's
  deployment identity (`sol.toml` stays language-free).
- A workspace containing both TypeScript and OCaml units is supported, and
  `sol check` / `sol up` / `sol deploy` treat them uniformly.
- The generated unit's contents match what the end-to-end `demo_ts` run proves
  is required.
