---
id: FEAT-103
type: feature
severity: medium
title: TypeScript has an end-to-end path but no Sol inner loop - sol local run builds OCaml units only
source: operator review 2026-09-27 of the TypeScript path, who put it as "TypeScript has an E2E path but not a real Sol inner loop" -- users still run Node by hand, and the live-dev roadmap only ever described OCaml
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

## Completion notes

**Premise re-verified (2026-09-27, `origin/main` `2fff2cef`).** `dev_run` still
built `dune build <unit>/bin/main.exe` and launched that path for every selected
workload, whatever its declared language, and the roadmap had no dev-loop entry.
The failure the ticket recorded reproduces verbatim.

**What landed.**

- `cli/lib/local/sol_cli_local_run.{ml,mli}` decides, per workload, what to build
  and what to run. It starts nothing, so every adapter is testable without a
  cluster: `plan ~root ~facts services` either returns a whole plan or the list
  of per-unit refusals.
  - OCaml: one merged `dune build <units>/bin/main.exe` (concurrent dune
    invocations fight over the build lock, which is why the loop always built
    them together), then the compiled binary as the supervised process.
  - TypeScript: `npm run build --workspace <package>` in the npm project that
    owns the unit (the nearest ancestor whose `package.json` lists it — for
    Pluto, `app/demo_ts`; the package name is `order-svc` while the directory is
    `order_svc`, so the name is read from the unit's own `package.json`), then
    `node <entry>` with the entry from `main` or `<outDir>/index.js`. npm is
    never the supervised process: the loop kills the pid it started, so killing
    npm would leave the service behind.
  - A workload that declares nothing, a `language: typescript` unit with no
    readable `package.json`/`name`, and a unit whose dependencies are not
    installed (the error names the `npm ci` to run) each fail naming the unit.
- `cli/bin/cmd_local.ml`'s `dev_run` now resolves the whole plan, prints it, runs
  the builds, and supervises the launches — the same prefixing, `build_env`
  injection and Ctrl-C handling as before, now over `plan.launches`. It acts from
  the workspace root, so the loop works from a descendant directory.
- Docs: `docs/guides/TUTORIAL.md`'s local-iteration prose and comparison table
  are language-aware, `examples/pluto/app/demo_ts/README.md`'s "Run it locally"
  is now the Sol command instead of a manual `node … &` walkthrough (its
  `ensure-*.sh` steps were the AGENTS.md "`sol` commands only" violation), and
  `internal/planning/LIVE_DEV_DEPLOY_ROADMAP.md` records the loop and its
  per-language verdict.

**Evidence (real runs on a copy of `examples/pluto`, `npm ci` then the loop).**

```text
$ sol local run --scope=demo_ts
  Starting 2 service(s) from .
    [svc] demo_ts/order_svc → app/demo_ts/order_svc/dist/index.js
    [worker] demo_ts/fulfillment_worker → app/demo_ts/fulfillment_worker/dist/index.js

  Building...
  > build
  > tsc                 # twice, once per unit, in app/demo_ts
  Build done.

  Services running — press Ctrl-C to stop all.
[demo_ts/fulfillment_worker] … at fulfillment_worker/dist/index.js:94  # the worker runs and reaches Postgres
```

With dependencies not installed the loop refuses both units, naming the remedy:

```text
$ sol local run --scope=demo_ts
error: demo_ts/order_svc has no installed dependencies; run `npm ci` in app/demo_ts
error: demo_ts/fulfillment_worker has no installed dependencies; run `npm ci` in app/demo_ts
```

The OCaml path is unchanged — `sol local run --scope=payments` prints the same
plan line (`app/payments/charge_svc/bin/main.exe`) and runs the same merged dune
build — and a mixed selection (`sol local run`, no scope) plans all five units
with each one's own artifact before building anything.

**Behaviour changes, stated rather than discovered later.**

- The loop acts from the workspace root, so `sol local run` now works from a
  descendant directory (before, the root-relative dune targets failed there).
- A build failure now names the command that failed (`dune build … failed (exit
  1)` rather than `dune build failed (exit 1)`).
- The plan for every selected unit is resolved before anything is built or
  started: one undrivable unit refuses the whole run rather than starting a
  partial system.

**Tests.** `cli/test/test_local_run.ml` (8 cases): the OCaml adapter's merged
build and binary launch; the TypeScript adapter's npm build by package name in
the npm project root, its `node` launch and entry, the `tsconfig` `outDir` being
honoured by a standalone unit; a mixed selection using both adapters in selection
order; and four refusals (undeclared, no `package.json`, dependencies not
installed, one bad unit refusing the whole plan). The whole CLI suite, `dune
build`, `check_ocamlformat.sh --all` and the offline guards pass.

**Also in this PR:** `internal/pipeline/tickets/READY_FOR_ENGINEERING/BUG-060.md`
— a defect found while starting this ticket. This ticket's own frontmatter was
not valid YAML (a plain `source:` scalar containing `": "`), which made `soldev`
report it unreadable and silently omit it from `pipeline ls` while CI's
ticket-transitions guard passed; the guard never parses frontmatter. The
frontmatter is corrected here, and BUG-060 carries the reproduced evidence and
the fix.

**Demo/example:** the demo *is* the example, and this ticket updated it — the
`demo_ts` README now runs the units through Sol, and the tutorial documents the
same. No new example Dockerfile, so the `example-dockerfile-smoke` matrix is
untouched.

**Language parity: this is the parity work.** The dev-loop capability now has a
per-language verdict for both languages, recorded in the roadmap; `sol.toml`'s
schema, deployment identity, and what `sol up`/`sol deploy` do are unchanged, and
no wire-format, retry/DLQ, metric-vocabulary, lifecycle or secrets contract
changes.

**Deliberate non-goals (as the ticket states):** no `tsx`, watch or hot-reload —
that is a new capability, not parity — and REFAC-134 had not landed when this
merged, so whoever lands it second rebases `dev_run`'s spawn, which this PR
rewrote to carry a per-unit command.
