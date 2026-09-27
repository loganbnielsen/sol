---
id: FEAT-103
type: feature
severity: medium
title: TypeScript has an end-to-end path but no Sol inner loop - sol local run builds OCaml units only
source: operator review (2026-09-27) of the TypeScript path - "TypeScript has an E2E path but not a real Sol inner loop: users still have to run Node manually, and the live-dev roadmap is OCaml-only"
---

**Depends on:** FEAT-104.

The dependency is not cosmetic: this ticket makes the declared language the
loop's *input*, and (by decision, below) an undeclared workload cannot be run.
Without FEAT-104's producer, that would regress `sol new workspace` →
`sol local run`, which works today with no declarations at all — so FEAT-104
lands first, and this ticket's work builds on the declarations it writes.

**Merge order:** REFAC-134 also rewrites the same spawn in `cmd_local.ml`
(`dev_run`) to go through `Sol_cli_process`, and introduces the supervised
long-running-spawn API this ticket's loop should use. It is not a dependency —
start now and rebase whichever lands second; the overlap is confined to that one
function.

**Related:** FEAT-084 (unit scaffolding — who owns *creating* a TS unit, and the
`--language` selection FEAT-104 defers), FEAT-082 (the TS golden-path umbrella),
DEC-022 (language-neutral platform), FEAT-102 (qualifying TS for the production
profile — the *deploy* half of the same parity story), FEAT-033 (whose non-goal
the runtime glue was).

## The gap

`sol local run` — the fast edit-compile-run loop, distinct from `sol up`'s
Docker/k3d path — is hard-wired to OCaml. It is the one local-dev surface with
no TypeScript verdict, and nothing owns that: `internal/planning/
LIVE_DEV_DEPLOY_ROADMAP.md` ("Current Reality", Projects 1–5) does not mention
the dev loop at all, and no ticket did either.

## Evidence (real run, 2026-09-27, CLI built from `cf199c5b`)

In a copy of `examples/pluto` (the TS units are discovered fine — discovery is
language-neutral, keyed on the `_svc`/`_worker`/`_fn` suffix and a Dockerfile):

```text
$ sol local run --scope=demo_ts
  Starting 2 service(s) from .
    [svc] demo_ts/order_svc → app/demo_ts/order_svc/bin/main.exe
    [worker] demo_ts/fulfillment_worker → app/demo_ts/fulfillment_worker/bin/main.exe

  Building...
Error: Don't know how to build app/demo_ts/order_svc/bin/main.exe
error: dune build failed (exit 1)
```

It does not degrade; it takes the TS units into the loop and then fails on them.

Positive control on the assumption (the same tree, the two conventions):

```text
$ cat app/payments/charge_svc/bin/dune          # an OCaml unit
(executable (name main) (libraries pluto_payments_charge_svc sol-svc sol-obs …))

$ python3 -c 'import json;print(json.load(open("app/demo_ts/order_svc/package.json"))["scripts"])'
{'dev': 'tsx src/index.ts', 'build': 'tsc', 'start': 'node dist/index.js'}
```

The loop's artifact path is a real dune target for the OCaml unit and does not
exist for the TS one: the OCaml unit has `bin/`, the TS unit has `src/` plus
`package.json`/`tsconfig.json`. (`sol local run` *also* fails for the OCaml unit
in a switch where `prepare-framework-deps.sh` has not been run — `Library
"sol-obs" not found` — but that is the documented DEC-025 dev bootstrap, not
this finding; the TS failure above is a different one and is not fixed by it.)

## Where the OCaml assumption lives

`cli/bin/cmd_local.ml`'s `dev_run`, in four places, none of which is a language
*declaration*:

1. the build command — one `eval $(opam env); dune build <units>/bin/main.exe`;
2. the artifact path — `<unit-dir>/bin/main.exe`;
3. the launch — `_build/default/<unit-dir>/bin/main.exe` as a native process;
4. the project root it implies — a unit is its own build root, while a TS unit's
   build root is the npm project above it (`examples/pluto/app/demo_ts` owns
   `package.json` + lock with `workspaces: [order_svc, fulfillment_worker]`).

## The decision (operator, 2026-09-27)

- **The declared language is the input, and nothing else is.** It comes from
  `sol.yml` via the workspace model — which already carries it (REFAC-130). No
  inference from `package.json`, `tsconfig.json`, `dune` or `.ml` when the
  declaration is absent: an undeclared workload is a per-unit error naming the
  unit and the line to add (`language: ocaml | typescript`). Once the language is
  *known*, the language's own adapter may read language-native metadata — for
  TypeScript, `package.json` for the npm package name and project layout, which
  is toolchain configuration, not language inference.
- **Production-parity semantics.** TypeScript builds through npm and then
  launches the built artifact directly with `node`. npm is never the supervised
  process: the loop kills the pid it spawned, and the OCaml side already runs the
  built binary rather than `dune exec` for the same reason. No `tsx`, no watch or
  hot-reload in this ticket — that is a new capability, not parity.
- **Mixed scopes are per-unit.** A scope containing both languages runs each unit
  through its own adapter; a unit the loop cannot drive fails naming itself,
  never a `dune build` error on a path that cannot exist for it.

## Remediation

- Give the dev loop a per-unit build/run adapter selected from the model's
  declared language, keeping discovery and selection unchanged:
  - OCaml — as today: `dune build <unit>/bin/main.exe`, then run
    `_build/default/<unit>/bin/main.exe`.
  - TypeScript — resolve the unit's npm project (the nearest enclosing
    `package.json` whose `workspaces` list contains the unit's package, else the
    unit itself), build with `npm run build --workspace <package name>` from that
    root (`cwd` — `Sol_cli_process.cmd` already takes it), then run the built
    entry (`node <unit>/dist/index.js`, the layout the unit's `tsconfig.json`
    declares) as the supervised process.
  - Anything else, or nothing declared — a per-unit error naming the unit and
    what it needs: a declaration, or `npm ci` in its project root when
    `node_modules` is missing.
- Extract the adapter so it is a pure function of (unit, model) — testable
  without a cluster — and keep the existing output prefixing, `build_env`
  environment and Ctrl-C supervision.
- Record the per-language verdict where the live-dev stream is planned: the
  roadmap's current-reality and project lists name the dev loop, and the
  tutorial's `sol local run` comparison table (`docs/guides/TUTORIAL.md`, "When
  to use `sol local run` vs `sol up`") stops saying "Native OCaml binaries".
- No change to `sol.toml`'s schema, to deployment identity, or to what `sol up` /
  `sol deploy` do.

## Acceptance criteria

- `sol local run --scope=<ts-domain>` in `examples/pluto` builds both TS units
  through npm and runs them from their built artifacts, prefixed exactly as the
  OCaml units are, with no manual `npm`/`node`/`ensure-*.sh` step.
- A mixed workspace (`sol local run` with no scope, or a scope spanning both
  languages) runs both adapters in one invocation.
- An undeclared workload, an unknown language and a missing `node_modules` each
  fail per unit with a message naming the unit and the remedy — and the adapters
  are covered by unit tests that fail without the fix (no cluster required).
- Demo/example: this changes what an app author does, so the same ticket updates
  the runnable example — `examples/pluto/app/demo_ts/README.md`'s "Run it
  locally" section replaces its manual `node …/dist/index.js &` walkthrough and
  its `ensure-*.sh` steps with the Sol commands (the `bash`-script steps are an
  AGENTS.md "`sol` commands only" violation) — and the tutorial's local-iteration
  section shows the TypeScript variant. No new example Dockerfile is involved, so
  the `example-dockerfile-smoke` matrix is untouched.
- Language parity: this ticket *is* the parity work for the dev-loop capability;
  it does not change the wire format, retry/DLQ semantics, metric vocabulary,
  lifecycle, or config/secrets contracts, so no companion verdict is needed for
  them.

## Probe

The existence-check half of the premise — does the loop drive a TypeScript
unit's toolchain yet — is declared so `pipeline check`/`ls` can evaluate it:

```yaml
premise: "rg -q 'npm run build|dist/index\\.js' cli/bin/cmd_local.ml"
```

Any faithful implementation of the decision above (build through npm, launch the
built artifact) contains one of those strings. If a future implementation drives
the toolchain another way the probe will not match, which reports the ticket as
actionable rather than stale — the safe direction.
