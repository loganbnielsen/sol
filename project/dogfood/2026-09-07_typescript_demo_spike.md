# TypeScript Demo Parity Spike — 2026-09-07

Ticket: FEAT-033
Engineer: Claude (automated)
Machine/OS: Linux WSL2

## What was built

`examples/pluto/app/demo_ts/order_svc/` and
`examples/pluto/app/demo_ts/fulfillment_worker/` — a TypeScript port of
`examples/local-demo`'s functional shape, placed as a new domain
(`demo_ts`) inside the existing `pluto` example workspace so `sol up`/
`sol dev`'s directory-suffix discovery covers them with zero CLI changes
(confirmed by reading `sol_cli_manifest.ml::discover_services` — it only
checks for a `_svc`/`_worker`/`_fn` suffix and a `Dockerfile`, nothing
about `pluto`'s existing domains needed to change).

Flow: `POST /orders` → `order_svc` registers/checks its JSON schema against
the Redpanda-embedded schema registry, encodes the message in Confluent
wire format, publishes to Kafka with a hand-generated W3C `traceparent`
Kafka header → `fulfillment_worker` decodes/validates the message,
continues the trace as a child span, writes to Postgres. Both services
expose Sol-named Prometheus metrics and push them to Pushgateway (this
repo's local Prometheus only scrapes Pushgateway, not services directly —
see Friction below), and push structured logs to Loki.

Ecosystem libraries used as intended (not under test): `kafkajs`, `pg`,
`prom-client` (including its built-in `Pushgateway` client), `fastify`,
`@opentelemetry/*` (SDK + OTLP HTTP exporter to Tempo).
`-fn` was **not** built — per the ticket, it was optional and judged to add
little new information about cross-service wiring beyond what svc+worker
already exercises.

## Verified end-to-end (real infra, not simulated)

Ran both services as plain `node` processes (matching how
`examples/local-demo`'s own binary is run — no `sol dev up`/k8s involved)
against this repo's already-running local infra (Redpanda/schema registry,
Postgres, Loki, Tempo, Prometheus, Pushgateway):

- `POST /orders` → HTTP 202, message flows through Kafka to the worker.
- Row written to `fulfilled_orders_ts` in Postgres.
- `sol_svc_requests_total`/`sol_svc_request_duration_seconds` on
  `order_svc`'s own `/metrics`; `sol_worker_messages_total`/
  `sol_worker_message_duration_seconds` on the worker's — both also visible
  in Prometheus itself via the Pushgateway relay.
- Log line for the request visible in Loki, including a `trace_id` field.
- **A single Tempo trace spans both services**: queried
  `/api/traces/<trace_id>` and confirmed `receive_order` (order-svc-ts) and
  `fulfill_order` (fulfillment-worker-ts) both present under the same trace
  — the cross-service tracing goal fully works.
- **Schema rejection, tested at both enforcement points**:
  - Registry-level: `POST /compatibility/subjects/.../versions/latest`
    with a breaking schema change (dropping the required `quantity` field)
    correctly returned `{"is_compatible":false}` under `FULL`
    compatibility — matches `kafka_service_schema.ml`'s `Schema.check`.
  - Consumer-level: published a raw malformed message directly to the
    topic (valid wire header, JSON missing `quantity`); the worker logged
    `rejected message: Error: quantity is required and must be an
    integer`, incremented `sol_worker_messages_total{status="decode_error"}`,
    did **not** write a row to Postgres, and kept running — no crash.
- Graceful shutdown: `SIGTERM` to `order_svc` closed Fastify and exited
  immediately; `SIGTERM` to `fulfillment_worker` took ~2–3s (kafkajs
  consumer-group leave protocol) before exiting cleanly.

**Not verified**: Grafana dashboard rendering. Port 3000 was already bound
by an unrelated `kubectl port-forward` to a k3d cluster's own Grafana from
prior work in this environment; `ensure-grafana.sh` refused to start a
conflicting container (correctly — see its own conflict-detection logic).
Did not kill that port-forward since it belongs to state outside this
ticket's scope. The underlying data (Loki logs, Tempo trace, Prometheus
metrics) all independently confirmed present via each system's own query
API, so this is very likely cosmetic, but "renders in Grafana" specifically
was not visually confirmed.

## Line/file count by concern

```
fulfillment_worker/src/db.ts          30   Postgres (ecosystem: pg)
fulfillment_worker/src/index.ts      107   wiring/orchestration
fulfillment_worker/src/loki.ts        35   Sol convention: log push shape
fulfillment_worker/src/metrics.ts     21   Sol convention: metric naming
fulfillment_worker/src/tracing.ts     47   Sol convention: trace propagation
fulfillment_worker/src/wire.ts        45   Sol convention: wire format + decode validation
order_svc/src/index.ts               126   wiring/orchestration
order_svc/src/loki.ts                 37   Sol convention: log push shape
order_svc/src/metrics.ts              23   Sol convention: metric naming
order_svc/src/schemaRegistry.ts       81   Sol convention: schema registry protocol
order_svc/src/tracing.ts              49   Sol convention: trace propagation
                                      ---
                                      601   total
```

Grouping the "Sol convention" files (schema registry + wire/decode +
tracing + metrics naming + logging, excluding pure wiring/orchestration in
each `index.ts`): **~338 of 601 lines (56%)** exist purely to reproduce
conventions that an OCaml `sol-svc`/`sol-worker` app gets from a handful of
framework calls (`Kafka_service.register`, `Sol_obs.of_env`,
`Sol_obs.with_span`, `Worker.Make`). For comparison, `examples/local-demo`
(`demo.ml` + `events.ml`, which additionally includes the HTTP test client
and assertion runner this TS port doesn't have) is 566 lines total — same
order of magnitude, but the OCaml side spends almost none of it on these
five concerns because the framework absorbs them.

## Friction log

**Schema registry protocol.** Nothing in `kafkajs` or the wider npm
ecosystem knows about Confluent-style schema registries or the 5-byte
wire-format header (magic byte + big-endian schema ID). Had to read
`kafka_service_schema.ml` directly to port the exact HTTP calls
(`/compatibility/subjects/.../versions/latest`, `/config/<subject>`,
`/subjects/<subject>/versions`) and wire encoding byte-for-byte. This is
the single biggest "the contract wasn't written down anywhere except OCaml
source" gap — a TS author with no OCaml-reading instinct would have no way
to discover this convention exists at all short of guessing or asking.

**Trace propagation onto Kafka headers.** OpenTelemetry's context
propagation is built for HTTP/gRPC carriers; there's no ecosystem-standard
way to propagate a trace onto a Kafka message. Had to hand-format/parse
the W3C `traceparent` string and manually bridge it into OTel's
`SpanContext`/`context.with` API on the consumer side. Correct, but this
is exactly the kind of glue nobody would get right by accident, and got
zero help from either `kafkajs` or `@opentelemetry/api`.

**Local Prometheus scrapes Pushgateway only.** `platform/local/config/
prometheus.yml` has a single static `pushgateway` scrape job — it doesn't
scrape arbitrary local processes. This matches `examples/local-demo`'s own
push-based approach (it's a one-shot binary), but a long-running TS service
had to add a periodic push loop instead of a one-time push. Not a TS-vs-
OCaml issue — it's a property of the local dev harness — but worth noting
since a real k8s deployment scrapes `/metrics` directly via
`prometheus.io/scrape` annotations and wouldn't need this at all.

**Host port collisions running bare Node processes locally.** `sol-worker`'s
documented metrics port (9090) collides with the local Prometheus
container's own host port mapping; `order_svc`'s natural HTTP port (8080)
also hit a collision. Had to run on 9190/8180 for this spike. Irrelevant
under real k8s (each pod owns its own network namespace) — purely an
artifact of running two bare processes on a host that already has this
repo's own infra containers up.

**`fnm`-managed Node wasn't on `PATH` for `npm` specifically.** `node`
resolved correctly via a `~/.local/bin/node` symlink but `npm` fell through
to a stray Windows npm from WSL interop, which failed outright (UNC path
error). Environment-specific, not a Sol/TS finding — worked around by
using the fnm-managed npm binary directly rather than touching the user's
global `PATH`/symlinks.

**`pino` was speculative and got cut.** Initially added as "the idiomatic
structured logger" per the ticket's suggestion, but it was never actually
needed — the entire interesting problem is the Loki push shape/labels
(Sol's convention), not log formatting/performance, so plain
`console.log`/`fetch` did the job with less code. Worth remembering next
time: don't reach for an ecosystem library just because it's the "obvious"
choice for the general problem if the actual bottleneck is elsewhere.

## Capability table

| Capability | OCaml | TypeScript (raw) | Candidate helper? |
|---|---|---|---|
| HTTP routing | sol-svc | Fastify | No |
| `/healthz` | automatic | ~3 lines manual | No — trivial |
| Prometheus exposition | automatic | prom-client | No |
| Metric naming convention | automatic | ~44 lines manual (both services) | Maybe — small, but easy to get subtly wrong (wrong label set breaks cross-language dashboards silently) |
| Kafka transport | kafka-eio | KafkaJS | No |
| Schema registry convention | sol-worker | 81 lines hand-rolled HTTP protocol | **Likely** — highest-value target found; requires reading OCaml source to discover it exists at all |
| Confluent wire format | kafka-eio | 45 lines hand-rolled (encode+decode+validate) | **Likely** — bundle with the schema registry helper above, same concern |
| Trace propagation (HTTP → Kafka → worker) | sol-obs | 96 lines hand-rolled OTel context bridging | **Likely** — second-highest value; genuinely easy to get subtly wrong (e.g. wrong span kind, malformed traceparent) |
| Graceful drain (HTTP) | automatic | `fastify.close()`, ~2 lines | No |
| Graceful drain (Kafka consumer) | automatic | `consumer.disconnect()`, but ~2-3s and order-dependent w.r.t. metrics/db/tracing shutdown | Maybe — small code, but easy to get the shutdown *order* wrong |
| PostgreSQL | pg-eio | pg | No |
| Structured logging (formatting) | sol-obs | plain console/fetch sufficed, pino added no value | No |
| Loki push shape/labels | sol-obs | 35-37 lines hand-rolled push API + label convention | Maybe — smaller than schema/tracing, but same "undiscoverable convention" problem |

## Recommendation

Build, in this order, if/when a real TS user justifies it:

1. **`@sol/kafka`** (schema registry + Confluent wire format + trace-header
   propagation bundled together — these three showed up as one coherent
   93%-of-the-pain cluster in this spike, not three separate concerns).
   This is where an OCaml-only convention is genuinely undiscoverable from
   TypeScript-land without reading OCaml source.
2. **`@sol/obs`** (metric naming constants + Loki push helper) — smaller,
   lower urgency, mostly about consistency/typo-proofing rather than
   unlocking anything that was hard to build.
3. **`@sol/http`/`@sol/worker`** (routing/health/drain conventions) — the
   weakest case of the four; `/healthz` and `fastify.close()` are a few
   lines each and unlikely to be worth a dependency on their own. Only
   worth bundling as sugar once `@sol/kafka`/`@sol/obs` already exist.

This matches [[project_ocaml_only_risk]]'s prediction going in — the gap
was never "can TypeScript deploy on Sol" (it already could, unmodified),
it's specifically the schema-registry and trace-propagation conventions
that have no ecosystem equivalent and are undocumented outside OCaml
source.
