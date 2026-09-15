---
id: FEAT-084
type: feature
severity: medium
title: "sol new --language typescript - the TypeScript entry point"
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

So Sol does not need a language-aware manifest. It needs a **scaffold** that
emits the same unit shape with a TypeScript-idiomatic skeleton — consistent with
DEC-022: language-neutral platform, per-language idiomatic DX on top.

## Deliverable

`sol new workspace` (and/or `sol new`) gains `--language <name>`, defaulting to
today's behaviour (OCaml) so nothing existing changes. For `typescript` it
emits:

- the same workspace/unit structure and `sol.toml` shape as today;
- a TS skeleton (Fastify / pg / kafkajs / prom-client) instead of `.ml`/`dune`;
- the runtime glue the platform owns (health/readiness, graceful drain,
  trace/metric wiring) — **as determined by FEAT-082's walk**, not assumed here;
- discovery/`sol.toml` parity so `sol check` / `sol up` / `sol deploy` treat it
  identically to an OCaml unit.

## Non-goals

- Not a language field in the manifest (the demo proves none is needed).
- Not publishing `@sol/*` (DEC-023).
- Not the runtime-glue decision (FEAT-082's walk and its child tickets).

## Acceptance criteria

- `sol new <name> --language typescript` produces a workspace that `sol check`
  accepts and that builds with `npm ci && npm run build`.
- No OCaml toolchain is required on that path.
- Default (no `--language`) behaviour is unchanged.
- The scaffold's runtime glue comes from FEAT-082's gap findings, not from
  assumptions made here.
