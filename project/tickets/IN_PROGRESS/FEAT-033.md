---
id: FEAT-033
type: feature
severity: medium
source: architecture discussion 2026-09-07 — verified Sol's CLI/deploy layer (discovery, docker build, k8s manifest render) is already language-neutral; expanded from an svc-only spike to full parity with examples/local-demo after deciding the interesting question is cross-service wiring (schema registry, tracing, metrics), not just "can a TS container deploy"
branch: feat-033/typescript-demo-parity-spike
worktree: ../sol-feat-033-typescript-demo-parity-spike
---

**Depends on:** None.

Build a TypeScript port of `examples/local-demo` — svc → Kafka (schema
registry, trace propagation) → worker → Postgres → Loki/Prometheus/Tempo/
Grafana — hand-rolling Sol's *conventions* on top of native TS libraries,
to measure what a `@sol/*` helper package layer would actually need to
provide before deciding whether to build one.

## Why

Sol's CLI/deploy layer (`sol_cli_manifest.ml` discovery, `docker build`,
k8s manifest render) is already proven language-neutral — see
[[project_ocaml_only_risk]]. The open question was never "can a TS
container deploy," it's "what do you lose by not having `sol-svc`/
`sol-worker`/`sol-obs`'s TS equivalent." That layer isn't a client library
(TS already has `kafkajs`/`pg` for that — those are never shared across
languages, same as OCaml's `kafka-eio`/`pg-eio` are OCaml-only). It's a set
of *conventions* on top of those clients:

- `sol-worker`: schema-registry-enforced event contracts (a consumer
  rejects a message that doesn't match the registered schema —
  `Kafka_service.MESSAGE` / `kafka_service_schema.ml`)
- `sol-obs`: W3C `traceparent` propagation from HTTP request through Kafka
  message to worker (see `examples/local-demo/bin/demo.ml`'s header
  comment), standardized metric names/labels, Loki-shaped structured logs

Whether a TS worker can be a first-class citizen of the *same* Grafana
dashboards, the *same* schema-registry guarantees, and the *same*
distributed traces as an OCaml service — that's what "easy to wire svc to
worker" actually requires, and it's only visible by building the real
thing end to end, not a single isolated `-svc`.

## Goal

Add `examples/pluto-ts/` (or a `ts/` subtree under `examples/pluto/` —
pick whichever keeps `sol up`/`sol dev`'s discovery working unmodified,
note the choice in the findings doc) that mirrors `examples/local-demo`
functionally:

```
HTTP client
    │  POST /orders {order_id, item, quantity} + X-Correlation-Id
    ▼
order_svc        (TypeScript, hand-rolled contract)
    │  publishes OrderPlaced with W3C traceparent header
    ▼
Kafka  (schema registered against the same registry OCaml uses)
    │
    ▼
fulfillment_worker  (TypeScript, hand-rolled contract)
    │  records fulfilled order in PostgreSQL
    ▼
Loki (logs) · Prometheus (metrics) · Tempo (traces) · Grafana
```

**Use idiomatic TS ecosystem libraries underneath — that's not the thing
under test.** `kafkajs` for Kafka, `pg` for Postgres, `prom-client` for
Prometheus exposition, OpenTelemetry (or its raw OTLP HTTP export, either
is fine) for traces, Fastify/Express for HTTP routing, `pino` for
structured logging. These are the TS equivalents of `kafka-eio`/`pg-eio`/
`obs-prometheus-eio`/etc — not Sol helpers, just how TS talks to these
systems. Using them isn't cheating; refusing them would test "can I avoid
npm," not "what does Sol add."

**Hand-implement only the Sol-specific conventions on top of those
libraries — no `@sol/*` package exists yet, and inventing one here would
defeat the point.** Concretely, per service:

`order_svc` (`-svc` contract, matching `framework/sol-svc/lib/service.ml`):
- Read `PORT` env, default 8080.
- `GET /healthz` → `200 {"status":"ok"}`.
- `GET /metrics` via `prom-client`, with a request counter + latency
  histogram matching `sol_svc_requests_total`/
  `sol_svc_request_duration_seconds`'s name/label shape — the *naming
  convention* is Sol-specific even though the exposition mechanism isn't.
- `POST /orders` → publishes `OrderPlaced` to Kafka via `kafkajs`, checked
  against the schema registry the same way `kafka_service_schema.ml` does
  (a plain HTTP call to `SCHEMA_REGISTRY_URL` — this protocol call is Sol's
  convention, not a library's), with a `traceparent` header propagated
  from the incoming request onto the outgoing Kafka message (via
  OpenTelemetry's context API or by hand — either is fine, the point is
  whether the propagation glue is Sol-specific work).
- SIGTERM → stop accepting connections, drain in-flight requests, exit.

`fulfillment_worker` (`-worker` contract, matching
`framework/sol-worker/lib/worker.ml`):
- Consumes `OrderPlaced`, validates against the same registered schema.
- Continues the trace as a child span of the `traceparent` it received,
  exported to Tempo.
- Writes the fulfilled order to Postgres via `pg`.
- Exposes `/metrics` on port 9090 (per-message counter/histogram via
  `prom-client`, Sol's naming convention).
- SIGTERM → finish in-flight message, exit (no k8s probe currently exists
  for workers per `sol_cli_manifest_yaml.ml` — don't invent one here).
- Structured logs via `pino`, shaped to match what `examples/local-demo`
  pushes to Loki (the field shape/labels are Sol's convention; `pino` is
  just the logger).

Skip `-fn` for this ticket unless it's cheap once the above two are done —
`sol-fn`'s Pushgateway-push pattern is simpler than svc/worker and adds
little new information about cross-service wiring. Note in the findings
doc whether it was included.

## Deliverable

1. The demo, actually run end-to-end against the same local infra scripts
   `examples/local-demo` uses (`ensure-broker.sh`, `ensure-postgres.sh`,
   `ensure-loki.sh`, `ensure-tempo.sh`, `ensure-pushgateway.sh`,
   `ensure-prometheus.sh`, `ensure-grafana.sh`) — confirm a trace shows up
   in Tempo spanning both services, dashboards render in Grafana, and a
   schema-incompatible message is actually rejected by the worker.
2. A findings note (`project/dogfood/2026-XX-XX_typescript_demo_spike.md`)
   covering:
   - Line count / file count, OCaml `local-demo` vs. TS port, broken down
     by concern (routing/health/metrics vs. Kafka+schema vs. tracing vs.
     Postgres vs. logging) — this is the real signal for where a helper
     package would pay off most.
   - Every point of friction, ambiguity, or place the TS code diverged
     from the OCaml conventions because the contract wasn't written down
     anywhere except OCaml source.
   - A capability table, one row per concern, judging whether it's
     "automatic in OCaml, ecosystem-library-covered in TS, no helper
     needed" vs. "automatic in OCaml, hand-glued Sol-specific code in TS,
     candidate helper" — e.g.:

     | Capability | OCaml | TS (raw) | Candidate helper? |
     |---|---|---|---|
     | HTTP routing | sol-svc | Fastify | No |
     | `/healthz` | automatic | manual | maybe |
     | Prometheus exposition | automatic | prom-client | No |
     | Metric naming convention | automatic | manual | likely |
     | Graceful drain | automatic | manual | likely |
     | Kafka transport | kafka-eio | KafkaJS | No |
     | Schema registry convention | sol-worker | manual | likely |
     | Trace propagation | sol-obs | OTel + manual glue | likely |
     | PostgreSQL | pg-eio | pg | No |
     | Structured logging | sol-obs | pino | maybe |

   - A concrete recommendation: which of `@sol/http`, `@sol/worker`,
     `@sol/obs` (or some other split) look worth building, in what order,
     based on where the friction actually was — not speculation.

## Not in scope

- No `@sol/*` npm package — this ticket produces the evidence for whether
  to build one, it doesn't build one.
- No `sol new --language typescript` scaffold template.
- No Python. Explicitly TypeScript-only for now.
- No changes to `sol_cli_manifest.ml`/`sol_cli_manifest_yaml.ml`/discovery
  — if this spike finds the CLI itself needs a change, that's a new ticket.
- No Kafka schema-registry client library and no `@sol/*` package of any
  kind — those HTTP calls and any Sol-naming/propagation glue must be
  hand-written so the friction is visible. Ordinary ecosystem libraries
  (`kafkajs`, `pg`, `prom-client`, OpenTelemetry, Fastify/Express, `pino`)
  are expected and encouraged, not a workaround.
