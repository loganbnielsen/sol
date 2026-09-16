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

## One successful transaction, followed end to end (2026-09-16)

The request contract was read from source rather than probed: `POST /orders`
requires `{order_id, item, quantity}` (Fastify's AJV body schema, `required:
["order_id", "item", "quantity"]`). Both earlier probes had 400'd *before the
handler ran* — which is why they produced no span.

One order, marker `e2e-1789583116`:

```text
POST /orders  {"order_id":"e2e-1789583116","item":"widget","quantity":3}
  → 202 {"accepted":true}
  → order-svc-ts  produced to sol-demo-ts-orders (wire-encoded, schemaId, traceparent header)
  → fulfillment-worker-ts  consumed it
  → [worker] fulfilled  order=e2e-1789583116  item=widget
  → Postgres fulfilled_orders_ts: e2e-1789583116|widget|3|e2e-1789583116
```

**PASS — the whole data path works**, including the correlation id surviving from
the HTTP header through the Kafka record into the stored row.

**Traces WORK — correcting the previous "unresolved".** There had simply never been
a request that reached the handler, so Tempo was legitimately empty. For this
transaction:

```text
order-svc-ts           receive_order  SPAN_KIND_PRODUCER  span=zS3WRWPF  parent=<root>
fulfillment-worker-ts  fulfill_order  SPAN_KIND_CONSUMER  span=W+lXmXrz  parent=zS3WRWPF
```

The worker's span is a **child of the service's span**, propagated through the
Kafka `traceparent` header. Cross-service propagation is demonstrated, not
inferred — the trace ID's timestamp matches the request exactly.

**PASS — metrics:** `sol_svc_requests_total{method="POST",route="/orders",status_class="2xx"} 1`.

**PASS, and better than expected — retry topology provisioned automatically.**
`@sol-fab/kafka` created a second consumer group and its retry topic without the
application naming either:

```text
group sol-demo-ts-fulfillment-worker          ← sol-demo-ts-orders[0]
group sol-demo-ts-fulfillment-worker-sol-retry ← sol-demo-ts-orders.sol-demo-ts-fulfillment-worker.retry[0]
```

**Still unresolved — logs in Loki.** Loki holds streams for `service=order-svc`,
but the newest is 18:04 and this 18:25 transaction is absent, and those entries are
logfmt while `@sol-fab/obs`'s `log()` emits JSON
(`console.log(JSON.stringify({service, level, msg, ...fields}))`) *and* pushes to
Loki directly (`src/loki.ts`). So the streams found are probably not this
application's. Needs a focused look at how TS logs reach Loki — direct push versus
stdout collection — rather than a general debugging session.

## FEAT-036 evidence: what the app hand-writes today

Read, not modified. This is the observation FEAT-036 should decide on, and it is
more than runtime config — the runtime *contract* is injected, but the **lifecycle
is hand-written and mirrors OCaml implementation details**:

`order_svc/src/index.ts`:

```text
const DRAIN_TIMEOUT_MS = 30_000; // matches sol-svc's default drain_timeout_s (service.ml)
const shutdown = async () => {
  if (shuttingDown) return; // SIGTERM/SIGINT can both fire; don't drain twice
  ... // races app.close() against drainTimeout,
      // "sol-svc races the drain against drain_timeout_s and force-cancels"
  await shutdownTracing();
};
process.on("SIGTERM", shutdown);  process.on("SIGINT", shutdown);
```

`fulfillment_worker/src/index.ts`: the same idempotence guard, plus
`metricsServer.close()`, `db.close()`, `shutdownTracing()` in order.

So the app currently reimplements: drain timeout matching an OCaml default,
idempotent signal handling, forced cancellation, ordered resource shutdown, and
OpenTelemetry flush. Recorded as **evidence**, not as a decision — the question for
FEAT-036 is whether that is framework-owned or legitimately application policy.
Note also that the retry/DLQ outcome machinery *is* already framework-owned
(`@sol-fab/kafka` provisioned the retry topology with no application involvement),
so the boilerplate is not uniform across concerns.

## Loki investigation — resolved to the platform, not the application (2026-09-16)

Question asked: which ingestion path does the platform actually intend, and which
streams were being observed?

**There is exactly one authoritative path, chosen by configuration.**
`@sol-fab/obs`'s `makeLokiPusher(lokiUrl, service)`:

```text
LOKI_URL unset  → console.log(JSON.stringify({service, level, msg, ...fields}))   # stdout
LOKI_URL set    → fetch(`${lokiUrl}/loki/api/v1/push`, stream {service})          # direct
```

`sol up` injects `LOKI_URL` (via the workspace ConfigMap), so the deployed
application takes the **direct-push** branch and emits logfmt lines — the same
shape the OCaml `Sol_obs` facade uses internally. The stdout JSON form is a
fallback for local/unspecified runs, not a competing strategy. So the "two
authoritative ingestion strategies" concern does not hold: they are alternatives,
and the platform picks one.

The entries previously found in Loki at `service=order-svc` were logfmt with
`span=receive_order`, i.e. the OCaml facade's shape, not this application's — hence
`order-svc-ts` was absent from the label index.

**The failure is in the local Loki, not in the application or in Sol.** Verified
from both directions against the single `loki-0` instance:

| Probe | Result |
| --- | --- |
| `POST` to `http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push` **from inside the pod** | `204 Accepted` — and never queryable |
| `POST` to `http://localhost:3100/loki/api/v1/push` **through the port-forward** | `204` — queryable immediately (only stream present) |
| Pod → Loki `GET /ready` | `200` |

So the application can reach Loki, chooses the intended path, and its pushes are
accepted; the in-cluster write is then silently discarded. One `loki-0` pod exists,
so this is not two instances disagreeing.

Note also that `fetch` only rejects on *network* errors, never on an HTTP error
status, so this class of failure is invisible to the application's
`.catch(err => console.error(...))`. That is worth knowing generally, but it is not
the cause here — the status was a genuine `204`.

**Conclusion:** environment/observability-infrastructure, not application
lifecycle or API boilerplate. Per FEAT-036's framing this therefore does **not**
feed the lifecycle-ownership decision.

**Not yet run** (the remaining two behavioural experiments): the SIGTERM/drain
test with the worker mid-flight, and retry → exhaustion → DLQ.

## #2 SIGTERM with a message in flight — forced-shutdown semantics (2026-09-16)

The message was made genuinely in-flight without touching the fixture: an
`ACCESS EXCLUSIVE` lock on `fulfilled_orders_ts` blocks the worker's `INSERT`, so
its `eachMessage` stays open.

Proof it was in-flight, not merely slow:

```text
marker drain-1789589779 sent → POST /orders 202
[worker] fulfilled for marker:        0        (handler still inside insertFulfilled)
sol-demo-ts-orders partition 0:  current-offset 3, log-end-offset 4, TOTAL-LAG 1
```

i.e. consumed, not committed. Then a graceful pod delete:

```text
terminationGracePeriodSeconds: 30
terminated after:              31s      → SIGKILLed at the grace boundary
offset after termination:      current-offset 3, log-end-offset 4   (still uncommitted)
```

**What happens at the forced-shutdown boundary (the case that matters):** the
process does not exit early and does not commit work it did not finish. It is
SIGKILLed at the grace period with the offset uncommitted, and Kafka **redelivers
to the replacement instance** once the group rebalances. The replacement then
completed it:

```text
[worker] fulfilled  order=drain-1789589779  item=widget      (replacement pod)
final: current-offset 4 = log-end-offset 4, TOTAL-LAG 0
```

So **no work is lost by force-cancelling an uncommitted message** — at-least-once
is preserved by Kafka, not by the application. That is a concrete semantic
available to a lifecycle abstraction.

Two observations, recorded rather than concluded:

- **The worker has no drain timeout of its own.** `order_svc` has
  `DRAIN_TIMEOUT_MS = 30_000` and races `app.close()` against it; the worker simply
  `await consumer.disconnect()`s and relies on Kubernetes' grace period to
  eventually SIGKILL it. Two units in one workspace model the same Sol boundary in
  two different ways, one of them implicitly.
- **The handler appears to have run twice** (two `fulfilled` log lines for the
  marker) while the database holds **one** row, because `insertFulfilled` is
  `ON CONFLICT (order_id) DO NOTHING`. So idempotency is currently
  **application-owned** — the app provided it, not Sol.

**Unverified, stated as such:** whether the `[fulfillment-worker-ts] draining...`
path actually ran before the SIGKILL. I queried the pod's logs *after* the delete,
when they are no longer retrievable, so the ordering between "stop taking new work"
and "finish the in-flight message" is **not** established by this run. That is the
next thing to instrument, and it is arguably more architecturally important than
the eventual API shape.

## #3 Retry → exhaustion → DLQ — PASS, with no application orchestration

Induced reversibly: `ALTER TABLE fulfilled_orders_ts RENAME TO …_hidden` makes
`insertFulfilled` throw, and the app's own policy (a DB failure is retryable)
returns Sol's `retry` outcome. Restored immediately afterwards.

```text
handler returns retryOutcome("db: …")
  → @sol-fab/kafka publishes to sol-demo-ts-orders.sol-demo-ts-fulfillment-worker.retry
  → retries, incrementing attempt
  → exhausts at maxAttempts 5
  → publishes to …fulfillment-worker.dlq
  → source offset committed, responsibility transferred
```

Evidence:

```text
sol_worker_messages_total{status="retry"} 5          (== RETRY_STRATEGY.policy.maxAttempts)
retry topic:  record for the marker, wire-encoded, 3 attempts visible
dlq topic:    {"order_id":"dlq-1789589087","item":"widget","quantity":1,
               "correlation_id":"dlq-1789589087"}      ← payload intact
source group: TOTAL-LAG 0, current-offset 3 = log-end-offset 3   ← transferred
```

The application never names a topic, a header, or an offset: it returns an
outcome, and `@sol-fab/kafka` owns publishing, delay, attempt accounting,
exhaustion, DLQ publication and offset transfer.

## The contrast, and what it implies for FEAT-036

| Sol-specific semantic | Owner today | Evidence |
| --- | --- | --- |
| Kafka retry / exhaustion / DLQ | `@sol-fab/kafka` | #3, zero app orchestration |
| offset / responsibility transfer | `@sol-fab/kafka` | #3, lag 0 after DLQ |
| trace propagation across services | `@sol-fab/kafka` + `@sol-fab/obs` | child span of the producer span |
| runtime endpoint discovery | Sol platform | 6 vars via ConfigMap |
| metrics conventions | `@sol-fab/obs` | `sol_svc_*` / `sol_worker_*` |
| HTTP draining | application | `app.close()` |
| signal handling | application | `process.on(SIGTERM/SIGINT)` |
| **Sol's 30s drain policy** | application | `DRAIN_TIMEOUT_MS = 30_000` |
| forced-shutdown semantics | *implicit* — k8s grace period | #2: no worker-side timeout |
| OTel flush ordering | application | `shutdownTracing()` |
| resource shutdown ordering | application | `metricsServer.close()` → `db.close()` |
| **idempotency** | application | `ON CONFLICT DO NOTHING` |

The principle this supports: **applications decide what happened to their work;
Sol owns the mechanics required to execute that decision safely.** #3 shows that
principle already realised for Kafka's hard part; #2 shows it is not realised for
process lifecycle. That is a conclusion from behaviour, not from aesthetics, and
it does not imply Sol should own Fastify or KafkaJS.

**Separately, for FEAT-036 to weigh, not evidence in itself:** the application
knows `sol-svc`'s OCaml `drain_timeout_s` default and reproduces it by hand. If Sol
promises consistent drain/shutdown behaviour across supported languages, an
application should not have to know an OCaml implementation detail to implement
the contract correctly.
