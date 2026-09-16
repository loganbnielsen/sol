---
id: FEAT-036
type: feature
severity: low
source: FEAT-033 findings (project/dogfood/2026-09-07_typescript_demo_spike.md) — weakest of the three candidate packages identified by that spike
---

**Depends on:** FEAT-034 and FEAT-035 conceptually (this would be built as sugar on top of them, per the recommendation below) — not a hard sequencing dependency, since this could also never get built at all.

Build `@sol/http`/`@sol/worker`, thin TypeScript packages wrapping Sol's HTTP-service and worker-lifecycle contract (`$PORT`, `GET /healthz`, drain-on-`SIGTERM`) — only if real usage shows this specific boilerplate is worth removing, which FEAT-033 found to be the weakest case of everything it measured.

## Status — premise refreshed 2026-09-15

FEAT-034/FEAT-035 have since been built (deliberately unblocked for the `demo_ts` showcase, not on organic demand) and dogfooded. That does **not** satisfy this ticket's bar: relaxing the gate for the Kafka package is not evidence that `@sol/http`/`@sol/worker` sugar is worth removing. FEAT-033's capability table still ranked this the weakest of the three candidates — most of what it would wrap is either trivial (a `GET /healthz` route is ~3 lines) or already correctly provided by the ecosystem library in use (Fastify's own `.close()`). Re-evaluate against real friction reports before building; do not infer "the gate was relaxed for A, therefore B's gate is met." Stays in `BACKLOG`: belongs/actionable and should-be-done-next remain separate decisions.

## What FEAT-033 actually found here

- `/healthz`: trivially small in Fastify (`app.get("/healthz", async () => ({ status: "ok" }))`) — one line, no review round flagged it.
- Prometheus exposition mechanism: `prom-client` already does this correctly; nothing Sol-specific about the mechanism (the *naming*, covered by FEAT-035, is the only Sol-specific part).
- Graceful HTTP drain: the one place this category had real teeth. `framework/sol-svc/lib/service.ml:357-373` (exception `Drain_timeout` at :180, `?drain_timeout_s = 30.0` at :236) races the server shutdown against the drain timeout and force-cancels via the `Drain_timeout` exception rather than hanging forever on a client holding a connection open. FEAT-033's first draft awaited `app.close()` unconditionally with no bound at all — round-1 adversarial review caught this specifically because the unbounded version *looks* correct until a client holds a connection open, which is exactly the kind of contract detail that's easy to skip without a spec to check against. The fix (`examples/pluto/app/demo_ts/order_svc/src/index.ts`'s `Promise.race([app.close(), drainTimeout])`) is ~15 lines — small, but non-obvious.
- Graceful Kafka-consumer drain: `consumer.disconnect()` plus a real 2-3s wait for `kafkajs`'s consumer-group leave protocol, and get the shutdown *order* right relative to metrics/DB/tracing teardown. Small code, same "easy to get the order wrong" risk as the HTTP case.

## Re-framed 2026-09-15 (DEC-022) — the acceptance test

DEC-022 changed the test this ticket is judged by. Its original gate ("build
only if real usage shows the boilerplate is worth removing") was a *demand*
test, and FEAT-033's table ranked it last. Under DEC-022 the question is
different: the TypeScript **golden path** (`sol new --language typescript` →
`sol local up` → write TS → `sol check` → `sol deploy`) is the adoption funnel,
and the demo hand-wrote exactly this boilerplate — `Promise.race([app.close(),
drainTimeout])` in `order_svc`, plus the consumer-drain and teardown-ordering
dance in `fulfillment_worker`. If a scaffolded TS service must hand-roll the
drain bound and the shutdown ordering, that is a golden-path DX gap, not merely
"sugar nobody asked for".

So the acceptance test becomes: **does FEAT-082's golden path require it?**
Either outcome closes the ticket:

- a `sol new --language typescript` scaffold that gets healthz/drain/shutdown
  ordering right without the author writing it, or
- FEAT-082 records that the ~15 lines are better inlined in the scaffold than
  extracted into a package.

What is no longer acceptable is leaving the question open on "no organic
demand" grounds. Stays in `BACKLOG` — FEAT-082 owns the sequencing; this is
evaluated as part of it, not before it.

## Why this is lower priority than FEAT-034/FEAT-035

FEAT-033's core finding was that Sol's real value-add is *policy nobody could otherwise discover* (schema-registry semantics, retry/crash routing, trace-propagation correctness) — categories where getting it wrong is silent and hard to detect. Almost none of that applies here: Fastify and `kafkajs` already do the mechanically correct thing for routing and disconnection; the only genuine gaps found (the drain timeout bound, the shutdown ordering) are small and were caught easily by review specifically *because* there was an OCaml reference to check against; they weren't independently rediscovered bugs across multiple review rounds the way the Kafka-policy bugs were. Build this only as convenience sugar once `@sol/kafka`/`@sol/obs` already exist and app authors are already depending on `@sol/*` conventions elsewhere — not as a starting point.

## Non-goals

- Not `@sol/kafka` (FEAT-034) or `@sol/obs` (FEAT-035).
- Not a routing framework — wrap Fastify/Express, don't replace them.

## Decision (2026-09-16) — build it, scoped to lifecycle only

FEAT-082's measured evidence answers the "Re-framed 2026-09-15" acceptance
test: the golden path does need this. Specifically:

- The app hand-copies **Sol's own drain-timeout policy**
  (`DRAIN_TIMEOUT_MS = 30_000`, commented "matches sol-svc's default
  drain_timeout_s") — an OCaml implementation detail the app should never
  have needed to know.
- The same lifecycle boundary is implemented two inconsistent ways across
  one workspace's two units: `order_svc` self-imposes a drain timeout and
  force-cancels; `fulfillment_worker` has none and relies implicitly on
  Kubernetes' `terminationGracePeriodSeconds`.

Scope stays exactly what the non-goals above already say no further than:
a minimal `@sol-fab/lifecycle` package owning only —

- idempotent `SIGTERM`/`SIGINT` handling (both apps hand-roll the same
  re-entrancy guard today),
- one drain-timeout default, shared instead of copied, matching
  `sol-svc`'s `drain_timeout_s`,
- forced-cancellation past that timeout (mirrors OCaml's `Drain_timeout`),
- an ordered shutdown-hook list, so "metrics server, then DB, then tracing
  flush" lives in one place instead of per-app.

Carried forward as non-goals: not wrapping Fastify/KafkaJS, not
idempotency (`ON CONFLICT DO NOTHING` stays application policy — Sol
cannot know business-level dedup semantics), not retry/DLQ (already
`@sol-fab/kafka`, per FEAT-082 #3).

Package mechanics follow the `sol-kafka`/`sol-obs` precedent (DEC-023):
own GitHub repo, own CI, npm publish under `@sol-fab/*` once ready — but
the npm bootstrap (2FA-gated token, `npm trust` flip) is a manual,
interactive step done once per new package, not something to attempt
unattended. Land the package with real tests and wire both `demo_ts`
units to it via a local path first; publishing is a mechanical follow-up,
not a blocker on this ticket's engineering work.

Moving to `READY_FOR_ENGINEERING`.
