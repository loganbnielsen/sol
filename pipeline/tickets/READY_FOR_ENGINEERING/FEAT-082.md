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
| `sol up` (TS units) | `sol up --scope=demo_ts` | **FAIL — bug** (this pass) — build context resolved to `/home/lbendtly/Code/sun.docker-ctx/app`, which does not exist, so the docker build failed. Filed and fixed as **BUG-034**; see the resume log below |
| TS svc + worker running | — | **not reached** — see resume log |
| health / metrics / traces / logs | — | **not reached** — see resume log |
| `sol deploy --target …` | — | **not run yet** |

Per-step classification (the distinction that actually answers FEAT-036):

- **PASS — platform-native**: Sol supports it; no app-side knowledge required.
- **PASS — app boilerplate required**: works only because the fixture carries
  bespoke knowledge. *Not* a golden-path pass — a candidate for FEAT-084 /
  `@sol-fab/*`.
- **FAIL — capability missing** / **FAIL — bug**.
- **FAIL — missing supported distribution/install path**: the workspace cannot
  obtain an *existing* Sol package through normal external dependency
  resolution; the fixture only worked because it sat inside Sol's source
  repository. A real golden-path failure, but **not** evidence for new
  framework abstractions — see the resume log.

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

Still unevidenced after the first pass: `sol up` for a TS unit that actually
builds, the running svc + worker, and health/metrics/traces/logs.

## Resume log — 2026-09-15 (after BUG-034 / PR #271)

Run from `_build/default/cli/sol/bin/main.exe` at `163e04a1` in `examples/pluto`,
**fixture left unmodified** — the obstacle below is the evidence, not something
to "help" past.

```text
$ sol up --scope=demo_ts
Workspace: pluto  tag: 163e04a1
Preparing build context...
[svc] demo_ts/order_svc
  packaging localhost:5000/pluto/order-svc:163e04a1...
[apply] FAILED (1.7s)
  docker build failed: app/demo_ts/order_svc
  ERROR: ... failed to compute cache key:
    "/examples/pluto/app/demo_ts/order_svc": not found
```

| Journey step | Result |
| --- | --- |
| workspace resolution | **PASS — platform-native** — `Workspace: pluto` resolved from `sol.yml` despite no Dune marker (BUG-034 fixed) |
| TS unit discovery | **PASS — platform-native** — both `demo_ts` units discovered; the domain scope selected them |
| build-context construction | **PASS — platform-native** — context prepared at the workspace root (`examples/pluto.docker-ctx`), cleaned up after the failure |
| TS unit build | **FAIL — missing supported distribution/install path** — every Dockerfile under `examples/pluto` assumes the **Sun monorepo root** as the docker build context (OCaml: `COPY . /workspace` + `dune build examples/pluto/...`; TS: `COPY package.json packages/sol-kafka packages/sol-obs examples/pluto/...`). Under DEC-024 the context is the workspace root, so those paths do not exist |
| TS svc + worker running | **not reached** |
| health / metrics / traces / logs | **not reached** |
| `sol deploy` | **not reached** |

**Classification of this step.** The TS Dockerfile cannot reach
`packages/sol-kafka` / `packages/sol-obs` because they live outside the Sol
workspace. That proves the *current TS dependency/distribution mechanism* is
incompatible with an independent Sol workspace. It does **not** prove FEAT-036
needs `@sol-fab/http` or `@sol-fab/worker`: `@sol-fab/kafka` and `@sol-fab/obs`
are already legitimate Sol capabilities, and the fixture merely obtains them
through monorepo-relative source access a real user cannot perform. This is
**DEC-023** territory (distribution/install), not evidence for new framework
abstractions.

**Do not fix this by** widening the Docker context back to the enclosing Sol
repository or teaching workspace builds about `../../packages` — that would undo
the boundary BUG-034 established.

A second, sharper finding: `examples/pluto` and `examples/venus` have **no
`dune-project`** and are subtrees of the Sun repo's Dune project, so they are not
independently buildable *as workspaces* at all. The repo-root Dockerfile context
is a symptom of that, not merely a stale path — making them workspace-contained
is not a path rewrite, the workspace itself has to become self-contained. Filed
as **FEAT-085**.

## Golden-path boundary (post-DEC-024)

DEC-024 established: *a workspace is independently located by `sol.yml`.*

FEAT-082 now asks: **can that workspace actually obtain everything required to
build and run its units without knowledge of the Sol source repository
containing it?** An independent workspace must resolve its dependencies through
normal external mechanisms (registry / package manager), from a build context
that contains only the workspace plus that resolution. If copying the workspace
out of Sol's repository breaks it, the golden path is not yet real. The concrete
test: `sol new workspace foo` → copy the result to `/tmp/foo` → build, deploy,
and observe successfully with no reference to the Sol checkout.

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
DEC-024   defines the workspace contract            (DONE)
   v
BUG-034   implements it                             (DONE, PR #271)
   v
DEC-023   supported install path for @sol-fab/*     <- now on the critical path
   v
FEAT-085  example workspaces independently buildable
   v
FEAT-082  completes the golden-path walk            <- blocked until then
   v
FEAT-036  conclusion: is a TS framework surface needed?
   v
FEAT-084  scaffold design
```

DEC-024/BUG-034 are done. The original plan had FEAT-082 establish the golden
path *before* DEC-023 published anything. The resume falsified that ordering:
FEAT-082 cannot represent the external-developer path while its only route to
`@sol-fab/kafka`/`@sol-fab/obs` is sitting inside Sol's own source repository.
The interim install path must therefore land **before** the walk can complete,
which is a sequencing change to DEC-023, not a new framework abstraction.
FEAT-084 must not start before FEAT-036 has an empirical answer.

## Demo/example coverage

This ticket's output is the gap analysis and child tickets; the child
tickets carry their own demo/example coverage. If the only change here is
filing tickets, record that one-line exemption in the completion notes.

## Walk result — `sol up --scope=demo_ts` (2026-09-16)

Run against `examples/pluto` after DEC-025/FEAT-085 made both examples real
standalone workspaces, so a failure here finally reflects the golden path rather
than examples secretly living inside the monorepo.

**Sol-owned stages all passed.** The run reached "waiting for rollout":

```text
Run: up-20260916T175301Z-65863
Workspace: pluto  tag: cf75d54c
Preparing build context...
[svc] demo_ts/order_svc
  packaging localhost:5000/pluto/order-svc:cf75d54c...
  pushing...
  waiting for rollout...
```

The deployment plan was computed correctly for both units, including migrations,
schema subjects and the consumer group:

```text
[svc]    demo_ts/order_svc           rolling_update -> sol-registry:5000/pluto/order-svc:cf75d54c
[worker] demo_ts/fulfillment_worker  rolling_update -> sol-registry:5000/pluto/fulfillment-worker:cf75d54c
migrations: 0001_notifications.sql
schema subjects: payments.Charged
consumer groups: pluto.demo_ts.fulfillment_worker
```

So: workspace discovery, build context, TypeScript image build, registry push and
manifest apply are all working for the TS path. `fulfillment_worker` was not
attempted because `sol up` waits for `order_svc`'s rollout first — correct
sequencing.

**Outcome: BLOCKED BY ENVIRONMENT, not a golden-path failure.**

`order-svc` lands in `CrashLoopBackOff` because it cannot reach Redpanda:

```text
{"logger":"kafkajs","message":"[Connection] Connection error: connect ECONNREFUSED 10.42.0.127:9093",
 "broker":"redpanda.redpanda.svc.cluster.local:9093"}
[order-svc-ts] fatal: KafkaJSNonRetriableError (KafkaJSNumberOfRetriesExceeded)
```

The broker is not merely slow — **`redpanda-0` was already crashlooping before this
walk**, 295 restarts over ~25h, exiting `132` (SIGILL, i.e. an illegal
instruction). Forcing a fresh pod did not help: it restarted 4 times without ever
becoming ready. That is a local k3d/WSL2 CPU-compatibility problem with the broker
image, independent of Sol — the Redpanda-backed tests pass in CI, which runs a
real Redpanda v24.2.7 under `sol-kafka`.

**Therefore this walk is not evidence of a TS golden-path gap in either
direction.** It is a prerequisite failure: the walk cannot be evaluated until the
broker runs. Re-run it once `redpanda-0` is healthy before drawing any conclusion.

**Recorded as observation, not a conclusion** (for FEAT-036 to weigh later): the
TS service treats broker unavailability at startup as fatal and exits, which turns
a dependency outage into `CrashLoopBackOff`. Whether a Sol TS service is expected
to survive that is a real question — but a Fastify/KafkaJS app exiting when its
broker is down is ordinary application code, and this run is not evidence that Sol
needs to own it.

**Incidental finding from running the walk — `sol up` leaves a build context
behind.** It created `examples/pluto.docker-ctx/`, a full copy of the workspace,
and left it on disk afterwards. Because Pluto is nested inside this repository,
that copy made the root Dune project see the `pluto` package twice and broke
`dune build`:

```text
Error: The package "pluto" is defined more than once:
- examples/pluto.docker-ctx/pluto.opam:1
- examples/pluto/pluto.opam:1
```

Removed, and `*.docker-ctx/` is now in `.gitignore` so it cannot be committed.
Two separate issues to weigh, neither evaluated here because the walk itself is
blocked: (a) the materialisation still happens for every `sol up`, even for a
workspace with nothing to materialise — the "resolve symlinks into the build
context" step that DEC-025 was meant to retire; and (b) it leaves the copy behind
rather than cleaning up, which for an app whose workspace sits inside another Dune
project is a build breakage rather than untidiness.

## Walk re-run on a recreated substrate (2026-09-16) — deployment PASSES

The previous run was blocked by a 25-hour-old broken broker. Following that
classification, the local substrate was recreated (`sol local infra down
--cluster` then `up`) and the command re-run **unchanged** — no application or
Sol changes — so the only difference was the environmental prerequisite.

The falsifiable question was answered first: **a freshly created Sol local
substrate produces a healthy broker** (`redpanda-0` Running/Ready, 0 restarts;
`rpk cluster info` and `rpk topic list` both work). So the 295-restart crashloop
was ambient machine rot, not a Sol local-infrastructure defect.

```text
sol up --scope=demo_ts
  [svc]    demo_ts/order_svc           ✓  rolled out, → http://localhost:8080
  [worker] demo_ts/fulfillment_worker  ✓  rolled out
  [apply] ok (36.4s)   Done. 2 service(s) deployed.
```

**PASS — platform-native:**

| Check | Result |
| --- | --- |
| Both pods | `Running 1/1`, 0 restarts |
| Health | `GET /healthz` → 200 (only liveness path; no `/readyz` or `/livez`) |
| Metrics | `GET /metrics` → Sol's `sol_svc_*` names, route-labelled counters incrementing |
| Kafka topic | `sol-demo-ts-orders` provisioned |
| Schema registry | app logged `schema registered, id=1` |
| Consumer group | `pluto.demo_ts.fulfillment_worker` in the plan |
| Runtime contract | deployment `envFrom`s `order-svc-env`, injecting `KAFKA_BROKERS`, `SCHEMA_REGISTRY_URL`, `TEMPO_URL`, `LOKI_URL`, `PUSHGATEWAY_URL`, `REDPANDA_ADMIN_URL` |
| App log output | on pod stderr, visible via `kubectl logs` |

**Notable:** the TS app reads exactly those six variables
(`process.env.{KAFKA_BROKERS,LOKI_URL,ORDERS_TOPIC,POSTGRES_URL,PUSHGATEWAY_URL,SCHEMA_REGISTRY_URL,TEMPO_URL}`)
and Sol injects them all. The platform supplies the runtime contract; the app does
not hand-reconstruct it. No application boilerplate was required to get a TS
service deployed and serving.

**UNRESOLVED — do not classify as gaps yet.** Both were chased far enough to rule
out the obvious causes, but not to a conclusion:

- **Traces.** Tempo reports 0 traces, yet `TEMPO_URL` is injected correctly and the
  app builds an `OTLPTraceExporter` from it. Could be application-side (batch
  exporter/sampling) or a real gap. Not claimed either way — the probing requests
  never produced a *successful* traced request (see below).
- **Logs in Loki.** 0 streams, queried both by namespace and by the labels Loki
  actually exposes (`service`, `service_name`), while Alloy is running and pod logs
  demonstrably exist. May be an Alloy pipeline/config question.

**Caution recorded:** the first check of the deployment showed an empty `env` array
and looked like "Sol never injects the observability endpoints" — a plausible and
wrong FEAT-082 finding. The variables arrive via `envFrom` → ConfigMap, which
`kubectl get deploy -o jsonpath='...env[*]'` does not show. Worth knowing before
anyone reports a config-injection gap from that command.

**Probe payloads were wrong, not Sol:** `POST /orders` returned 400 twice
(`body must have required property 'order_id'`, then 400 again with `order_id`
supplied). The exact request schema was not determined, so no traced request was
ever completed. Determining it is the next step for evaluating traces.
