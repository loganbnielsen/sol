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
| `sol local up` (infra) | `sol local status` | **PASS — platform-native** — k3d cluster `sol-local` (v5.6.0) already present; logs `healthy`, metrics endpoint unreachable. Infra was not re-provisioned this pass |
| `sol up` (TS units) | `sol up --scope=demo_ts` | **FAIL — bug** — build context resolved to `/home/lbendtly/Code/sun.docker-ctx/app`, which does not exist, so the docker build failed. Filed as **BUG-034** |
| TS svc + worker running | — | **not reached** — blocked by the row above |
| health / metrics / traces / logs | — | **not reached** — blocked by the row above |
| `sol deploy --target …` | — | **not run this pass** |

Per-step classification (the distinction that actually answers FEAT-036):

- **PASS — platform-native**: Sol supports it; no app-side knowledge required.
- **PASS — app boilerplate required**: works only because the fixture carries
  bespoke knowledge. *Not* a golden-path pass — a candidate for FEAT-084 /
  `@sol-fab/*`.
- **FAIL — capability missing** / **FAIL — bug**.

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
4. **`sol up` fails for a workspace with no dune markers.** `find_repo_root`
   (`cmd_up.ml:17-28`) keys on `dune-project`/`dune-workspace`;
   `examples/pluto` has neither (only `sol.yml`), so the context landed at
   `<repo>.docker-ctx` — outside the workspace — and the build died on
   `lstat .../app`. This is a **language-neutrality defect**, not fixture
   hygiene: a TypeScript-only workspace would walk to the filesystem root and
   use `/.docker-ctx`. Filed as **BUG-034**. Because it blocked the build, this
   pass did not reach the svc/worker/observability steps.

Still unevidenced: `sol up` for a TS unit that actually builds, the running
svc + worker, and health/metrics/traces/logs.

## Evidence bar for the resumed walk

**Resume at the exact failed command** (`cd examples/pluto && sol up
--scope=demo_ts`) after BUG-034 lands, and do **not** "help" the fixture past
problems prematurely — each obstacle is the evidence.

"Pod starts and an HTTP request returns 200" is **not** sufficient for the TS
golden path. The bar:

```text
TS svc                          TS worker
  builds                          builds
  deploys locally                 deploys locally
  becomes healthy                 consumes Kafka
  handles a request               uses Sol retry/DLQ semantics
  emits expected metrics          emits expected metrics/traces/logs
  emits expected traces           drains/terminates correctly
  logs visible through Sol
  drains/terminates correctly
```

Not a formal suite yet — the point is to **observe the path before designing the
abstraction**.

**What counts as a gap, and what doesn't.** Ordinary application/framework code
tells us nothing (writing a Fastify route, calling `kafkajs` directly). The
signal is **Sol-specific knowledge leaking into application code**: if every TS
service must know exactly how Sol expects SIGTERM draining, health readiness,
metrics lifecycle, trace propagation and shutdown ordering — or if a worker must
hand-assemble a particular lifecycle protocol to behave correctly *as a Sol
worker* — that is FEAT-036 evidence. Classify each step with the legend above;
"a knowledgeable Sol developer can make TS work" is not a pass.

## Dependency chain

```text
DEC-024   defines the workspace contract   (accepted, awaiting implementation)
   v
BUG-034   implements it
   v
FEAT-082  exercises the resulting platform  <- resume here
   v
FEAT-036  conclusion: is a TS framework surface needed?
   v
FEAT-084  scaffold design
```

DEC-024 does not depend on BUG-034; it is decided and pending implementation.
FEAT-084 must not start before FEAT-036 has an empirical answer.

## Demo/example coverage

This ticket's output is the gap analysis and child tickets; the child
tickets carry their own demo/example coverage. If the only change here is
filing tickets, record that one-line exemption in the completion notes.
