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

## Premise refresh (2026-10-02)

Verified against current `origin/main`; the gap stands, but several statements above are stale
and the blocking gate has cleared:

- **The CLI has a language concept now.** `Sol_cli_compat.language = Ocaml | Typescript`
  (`cli/lib/workspace/sol_cli_compat.ml`), and `sol new svc|worker|fn` records the unit's
  language in `sol.yml` through `Sol_cli_sol_yml.plan ~language:Sol_cli_compat.Ocaml`
  (`cli/lib/workspace/sol_cli_cmd_new.ml:142`). "The CLI has no language concept at all" is no
  longer true. `sol.toml` is still language-free, so the ownership boundary the ticket argues
  for is intact.
- **The gap is real and narrow.** `new_component` hardcodes `Ocaml`, no `sol new` subcommand
  accepts `--language`, and `platform/shared/templates/{svc,worker,fn}` are OCaml-only — there
  is no TypeScript template tree. A TypeScript author still cannot reach a running unit from
  `sol new`.
- **The gate has cleared.** FEAT-082 and FEAT-036 are `DONE`. FEAT-036's empirical answer is
  that the lifecycle glue belongs in the framework packages (true today: `@sol-fab/svc` and
  `@sol-fab/worker` own the bounded drain and shutdown ordering), so a TypeScript scaffold can
  call `runService`/`runWorker` the way `examples/pluto/app/demo_ts` does.
- **What remains is a scaffold feature with a layout constraint.** Per-unit `--language` is the
  natural boundary (the ticket's own argument, and the current CLI is unit-based). It needs a
  language dimension in `Sol_cli_scaffold_tree.copy`: the template root is
  `platform/shared/templates/<kind>/` and `plan` walks it recursively, so a
  `templates/<kind>/typescript/` subtree would also be copied by an OCaml `sol new` unless the
  walk is made language-aware. Then TypeScript template trees for `svc`/`worker`/`fn`, modelled
  on `demo_ts`, and a `--language` option on the three subcommands.
- **Triage:** promoted to `READY_FOR_ENGINEERING/` and implemented in Part A (below); Part B
  remains.

## Part A (2026-10-02) — svc and worker scaffolds

**Implemented.** `sol new svc|worker <domain>/<name> --language typescript` (default `ocaml`)
scaffolds a TypeScript unit from new template trees
`platform/shared/templates/{svc,worker}-ts/`, records `language: typescript` through the
existing `Sol_cli_sol_yml.plan`, and prints the `npm install && npm run build` next step. The
language selects a template variant (`Sol_cli_scaffold_tree`'s `kind` becomes `svc-ts` /
`worker-ts`), so an OCaml `sol new` is unaffected. The generated units call the published
`@sol-fab/svc`/`@sol-fab/worker` lifecycle contracts — healthz/readyz/metrics and the bounded
drain come from the packages, not hand-rolled glue (FEAT-036's answer) — and mirror
`examples/pluto/app/demo_ts`.

**Verified.** `dune runtest cli/test/inline` passes, including three new cases: the svc and
worker scaffolds' files and `sol.yml` `language: typescript`, and the `fn` refusal.
Scaffolding into a scratch workspace and running `npm install && npm run build` succeeds for
both the svc and the worker; `sol new svc ...` with no flag is unchanged.

**Not in Part A (Part B).** `sol new fn --language typescript` is refused with a named error:
the TypeScript `-fn` runtime contract is deferred (the framework-conventions `-fn` row), so
the scaffold cannot target it yet. Acceptance criterion 1's "function" and a generated-unit
end-to-end walk remain. The template `Dockerfile`s use `npm install` (a fresh scaffold has no
lockfile); whether a scaffold should produce or require one is part of Part B.


