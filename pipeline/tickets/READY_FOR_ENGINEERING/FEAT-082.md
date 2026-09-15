---
id: FEAT-082
type: feature
severity: medium
title: TypeScript golden path — sol new --language typescript through sol deploy (umbrella)
source: DEC-022 (application-language strategy) 2026-09-15 — the
  adoption-critical consequence
---

**Depends on:** DEC-022.

**Related:** DEC-013, DEC-023, FEAT-033, FEAT-036, FEAT-080, FEAT-081.

Make the TypeScript developer journey genuinely excellent end to end. This is
an **umbrella**: its deliverable is a real gap analysis against the journey
plus one implementation ticket per real gap — *not* the whole implementation
in one PR, and not a decision that any particular `@sol/*` package is the
answer.

## The journey (the acceptance test)

```text
sol new my-app --language typescript
  ↓
sol local up
  ↓
write ordinary TypeScript (Fastify / pg / kafkajs / prom-client)
  ↓
sol check
  ↓
sol deploy --target staging
  ↓
health / metrics / traces / logs work
```

…without reading the OCaml implementation or hand-reconstructing Sol's
runtime contract. This is DEC-022's "coherent DX" test — necessary, but
distinct from the capability matrix below.

## Problem

The journey does not exist end to end today. There is no
`sol new --language typescript` (a FEAT-033 non-goal), the TS demo is
hand-maintained, and the runtime glue a TS author must supply by hand —
health/readiness, graceful shutdown, config/secrets, trace defaults, metric
wiring, retry/DLQ (FEAT-081) — is exactly what the platform is supposed to
own. So a TypeScript developer hits Sol through a demo, not a scaffold.

## Deliverable

1. **Walk the journey for real**, from a clean checkout/install, and record
   every step that breaks, is missing, or requires reading OCaml source.
   Evidence per step (command + observed result), not inference.
2. **File one implementation ticket per genuine gap.** Do *not* assume
   `@sol/http`/`@sol/worker` are the answer — they are candidates. Where the
   Node ecosystem + generated config already delivers the Sol contract,
   record it as "already equivalent, no package needed" (DEC-022's verdicts).
3. **The entry point is its own ticket.** `sol new --language typescript`
   (scaffold + template + discovery/`sol.toml` parity) is the top of the
   funnel; capture it explicitly rather than treating it as a detail of some
   other gap.
4. **Keep the two levels distinct** (DEC-022): this umbrella owns the golden
   *path* (adoption/DX). The per-capability *matrix* (architectural parity)
   is maintained by the TS-parity inventory (FEAT-080's addendum), and this
   ticket should reference it rather than duplicate it.

## Non-goals

- Not a mandate to build any specific package; not a rewrite of `demo_ts`.
- Not the capability matrix itself (that is the inventory's job).
- Not publishing to npm — that is DEC-023.

## Acceptance criteria

- Every journey step above has a pass/fail recorded from a real run, with
  the command and observed result.
- Each failing/awkward step has either a child implementation ticket or an
  explicit "ecosystem already provides this" verdict.
- `sol new --language typescript` is captured as its own ticket.
- The child tickets reference DEC-022 so they inherit the parity
  definition rather than re-litigating it.

## Walk log — 2026-09-15 (in progress)

Run from a built CLI (`_build/default/cli/sol/bin/main.exe`, commit `e0678f71`);
scratch dir `/tmp/sol-walk`. Evidence is command + observed result.

| Journey step | Command | Result |
| --- | --- | --- |
| entry point | `sol new my-app --language typescript` | **FAIL** — `unknown command my-app`; no `--language` flag on any `sol new` subcommand; zero `typescript`/`--language` matches in `cli/sol/` |
| baseline scaffold | `sol new workspace walkapp` | PASS (OCaml) — 28 files; `.ml`/`dune`/`.ocamlformat`; next steps `eval $(opam env) && dune build`. No TS variant |
| TS declaration layer | `sol check` in `examples/pluto` | PASS — the TS units (`app/demo_ts/*/sol.toml`) are ordinary units, identical in shape to the OCaml ones; the toml schema has no language field |
| `sol local up` | — | **not run this pass** — needs k3d + Docker (~5 min provision); recorded as unverified, not as a pass |
| `sol deploy --target …` | — | **not run this pass** — needs a cluster/target |
| health / metrics / traces / logs | — | **not run this pass** — depends on the two above |

Findings so far:

1. **No TypeScript entry point.** `sol new --language typescript` does not exist
   and the CLI has no language concept. Filed as **FEAT-084**.
2. The journey text in this ticket does not match the real CLI surface: the
   scaffold's own next-steps are `sol local infra up` then `sol up`, not
   `sol local up`. Low severity, but this umbrella's acceptance test should use
   the real command names.
3. Language-neutrality at the *declaration* layer already holds — `sol.toml` and
   `sol check` handle TypeScript units with no changes — so the fix is additive
   (a scaffold), not a manifest/schema change.

Still unevidenced (the umbrella's open work): `sol local up` / `sol up` /
`sol deploy` and health/metrics/traces/logs for a TS unit. Those need a k3d
cluster + Docker.

## Demo/example coverage

This ticket's output is the gap analysis and child tickets; the child
tickets carry their own demo/example coverage. If the only change here is
filing tickets, record that one-line exemption in the completion notes.
