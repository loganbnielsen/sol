---
id: FEAT-103
type: feature
severity: medium
title: TypeScript has an end-to-end path but no Sol inner loop - sol local run builds OCaml units only
source: operator review (2026-09-27) of the TypeScript path - "TypeScript has an E2E path but not a real Sol inner loop: users still have to run Node manually, and the live-dev roadmap is OCaml-only"
---

**Depends on:** None.

**Related:** FEAT-084 (unit scaffolding — who owns *creating* a TS unit),
FEAT-082 (the TS golden-path umbrella), DEC-022 (language-neutral platform),
FEAT-102 (qualifying TS for the production profile — the *deploy* half of the
same parity story), FEAT-033 (whose non-goal the runtime glue was).

## The gap

`sol local run` — the fast edit-compile-run loop, distinct from `sol up`'s
Docker/k3d path — is hard-wired to OCaml. It is the one local-dev surface with
no TypeScript verdict, and nothing owns that: `internal/planning/
LIVE_DEV_DEPLOY_ROADMAP.md` ("Current Reality", Projects 1–5) does not mention
the dev loop at all, and no ticket does either.

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
   `package.json` + lock with `workspaces: [order_svc, fulfillment_worker]`, and
   the documented build is `npm run build -w order-svc -w fulfillment-worker`).

The TS ingredients already exist *in the units themselves* (each has `dev`,
`build`, `start` scripts). What is missing is that Sol drives them.

## Why this is not FEAT-084

FEAT-084 owns the path from `sol new` to a *created* TypeScript unit, and it
explicitly disclaims the runtime glue ("Not the runtime-glue decision"); its
acceptance is satisfied today by the language-neutral k3d path
(`sol local infra up` → `sol up --scope=<ts-domain>`), which CI runs as
`golden-path-smoke-ts`. This ticket owns the *run* surface instead, and the two
must not be bundled:

- The loop must work for hand-authored TS units, which is what Pluto's are and
  will remain until FEAT-084 lands — so it cannot depend on scaffolding.
- Conversely, letting FEAT-084 absorb the loop would let "scaffolding shipped"
  read as "the TypeScript journey works" while the inner loop stayed OCaml-only,
  which is the drift DEC-022's per-language verdict exists to prevent.
- The surfaces differ (`sol new` vs `sol local run`), as do their fixes.

## Open Questions

1. **Where does a unit's build/run recipe come from?** `sol.toml` has no
   language field and must not gain one (DEC-022 §7 keeps language out of
   deployment identity; FEAT-084's non-goals repeat it). Candidates, to be
   decided with the DX walk rather than here:
   - (a) *infer from the unit's own tree* — `package.json`/`tsconfig.json` beside
     it means the npm path, `dune`/`.ml` means dune. Local-dev only, so it does
     not put language into deployment identity, but it is still inference and
     must be stated as a deliberate local-dev exception if chosen;
   - (b) *read `sol.yml`'s declared `language:`* — the workspace model already
     carries each service's declared language (REFAC-130), so this is the
     cheapest correct input where it is declared; a workspace may leave a
     workload undeclared, so it needs a rule for that case;
   - (c) *an explicit build/run recipe in the unit's own `sol.toml`*
     (`[service] build = …`, `start = …`) — most explicit, but it makes every
     author write their toolchain into Sol config, including OCaml authors whose
     convention Sol already knows.

   *Recommended, for the operator's call:* (b), with (a) as the fallback for a
   workload that declares none. `sol.yml` is already where language is declared
   (the profile/compat check reads it there) and the workspace model already
   carries it, so the loop adds no inference of its own where the workspace is
   explicit, while the fallback keeps hand-authored units (Pluto's TS pair) and
   undeclared workspaces running. (c) is the one to avoid: it pushes a
   toolchain description onto every author to solve a problem Sol can already
   answer.
2. **Does the loop need `--scope`-level language mixing?** Selection is already
   per-unit, so a mixed run (`sol local run` with TS and OCaml units at once)
   must either work or fail per unit with a clear message. Decide which.
3. **Non-goal, stated so it is not smuggled in:** watch/hot-reload is a *new*
   capability, not parity. `sol local run` today builds once and runs until
   Ctrl-C; TS parity means the same, per language.

## Remediation

- Give the dev loop a per-unit build/run step that follows the decision in Open
  Question 1, keeping discovery and selection unchanged.
- A unit whose language the loop cannot drive fails with a message naming the
  unit and what it needs — never a `dune build` error on a path that cannot
  exist for it.
- Record the per-language verdict where the live-dev stream is planned: the
  roadmap's current-reality and project lists name the dev loop, and the
  tutorial's `sol local run` comparison table (`docs/guides/TUTORIAL.md`, "When
  to use `sol local run` vs `sol up`") stops saying "Native OCaml binaries".
- No change to `sol.toml`'s schema, to deployment identity, or to what `sol up`
  / `sol deploy` do.

## Acceptance criteria

- `sol local run --scope=<ts-domain>` in `examples/pluto` starts both TS units
  from their own build/run scripts and prefixes their output exactly as it does
  for OCaml units, with no manual `npm`/`node`/`ensure-*.sh` step.
- A mixed workspace runs both languages in one invocation, or refuses per unit
  with a message naming the unit and the missing recipe.
- The per-unit failure paths are covered by tests that fail without the fix
  (the loop's build/launch choice is testable without a cluster).
- Demo/example: this changes what an app author does, so the same ticket updates
  the runnable example — `examples/pluto/app/demo_ts/README.md`'s "Run it
  locally" section replaces its manual `node …/dist/index.js &` walkthrough with
  the Sol command (its `ensure-*.sh` steps are the AGENTS.md
  "`sol` commands only, no `bash` scripts" violation), and the tutorial's
  local-iteration section shows the TS variant. No new example Dockerfile is
  involved, so the `example-dockerfile-smoke` matrix is untouched.
- Language parity: this ticket *is* the parity work for the dev-loop capability;
  its verdict is recorded in the live-dev roadmap (above), and it does not
  change the wire format, retry/DLQ semantics, metric vocabulary, lifecycle, or
  config/secrets contracts, so no companion verdict is needed for them.

## Probe

The gap reduces to an existence check — does the dev loop drive a TypeScript
unit's own toolchain yet — so the ticket declares it:

```yaml
premise: "rg -q 'node dist/index\\.js|tsx src/index\\.ts' cli/bin/cmd_local.ml"
```

It succeeds when the loop runs the TS unit the way the unit's own `start`/`dev`
scripts declare it. If a future implementation drives the toolchain some other
way it will not match — the safe direction (the ticket stays visible and
`soldev pipeline check` reports it actionable rather than stale).
