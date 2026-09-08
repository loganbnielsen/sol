---
id: FEAT-036
type: feature
severity: low
source: FEAT-033 findings (project/dogfood/2026-09-07_typescript_demo_spike.md) — weakest of the three candidate packages identified by that spike
---

**Depends on:** FEAT-034 and FEAT-035 conceptually (this would be built as sugar on top of them, per the recommendation below) — not a hard sequencing dependency, since this could also never get built at all.

Build `@sol/http`/`@sol/worker`, thin TypeScript packages wrapping Sol's HTTP-service and worker-lifecycle contract (`$PORT`, `GET /healthz`, drain-on-`SIGTERM`) — only if real usage shows this specific boilerplate is worth removing, which FEAT-033 found to be the weakest case of everything it measured.

## Blocked on

Same demand signal as FEAT-034/FEAT-035 — not actionable now. Additionally, and unlike those two tickets: **this one may never clear the bar even if TS adoption happens.** FEAT-033's own findings doc capability table ranked this the weakest candidate of the three — most of what it would wrap is either trivial (a `GET /healthz` route is ~3 lines) or already correctly provided by the ecosystem library in use (Fastify's own `.close()`). Re-evaluate against real friction reports before building, don't build it just because FEAT-034/FEAT-035 got built.

## What FEAT-033 actually found here

- `/healthz`: trivially small in Fastify (`app.get("/healthz", async () => ({ status: "ok" }))`) — one line, no review round flagged it.
- Prometheus exposition mechanism: `prom-client` already does this correctly; nothing Sol-specific about the mechanism (the *naming*, covered by FEAT-035, is the only Sol-specific part).
- Graceful HTTP drain: the one place this category had real teeth. `framework/sol-svc/lib/service.ml:290-303` races the server shutdown against `drain_timeout_s` (default 30s) and force-cancels via a `Drain_timeout` exception rather than hanging forever on a client holding a connection open. FEAT-033's first draft awaited `app.close()` unconditionally with no bound at all — round-1 adversarial review caught this specifically because the unbounded version *looks* correct until a client holds a connection open, which is exactly the kind of contract detail that's easy to skip without a spec to check against. The fix (`examples/pluto/app/demo_ts/order_svc/src/index.ts`'s `Promise.race([app.close(), drainTimeout])`) is ~15 lines — small, but non-obvious.
- Graceful Kafka-consumer drain: `consumer.disconnect()` plus a real 2-3s wait for `kafkajs`'s consumer-group leave protocol, and get the shutdown *order* right relative to metrics/DB/tracing teardown. Small code, same "easy to get the order wrong" risk as the HTTP case.

## Why this is lower priority than FEAT-034/FEAT-035

FEAT-033's core finding was that Sol's real value-add is *policy nobody could otherwise discover* (schema-registry semantics, retry/crash routing, trace-propagation correctness) — categories where getting it wrong is silent and hard to detect. Almost none of that applies here: Fastify and `kafkajs` already do the mechanically correct thing for routing and disconnection; the only genuine gaps found (the drain timeout bound, the shutdown ordering) are small and were caught easily by review specifically *because* there was an OCaml reference to check against; they weren't independently rediscovered bugs across multiple review rounds the way the Kafka-policy bugs were. Build this only as convenience sugar once `@sol/kafka`/`@sol/obs` already exist and app authors are already depending on `@sol/*` conventions elsewhere — not as a starting point.

## Non-goals

- Not `@sol/kafka` (FEAT-034) or `@sol/obs` (FEAT-035).
- Not a routing framework — wrap Fastify/Express, don't replace them.
