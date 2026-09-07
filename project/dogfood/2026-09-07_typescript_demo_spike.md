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
    integer`, incremented `sol_worker_decode_errors_total`, did **not**
    write a row to Postgres, and kept running — no crash. (This run
    predates the round-1 adversarial-review fixes below, which split
    decode failures onto their own counter — see that section for why.)
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

Counts as of the final commit, after both rounds of adversarial-review
fixes below — regenerated via `wc -l` rather than left at a pre-fix
snapshot, since those fixes added real convention/wiring code (error
handling, drain timeout, topic provisioning, bounded HTTP calls, an extra
counter, AJV schema) that this table exists to measure:

```
fulfillment_worker/src/db.ts          37   Postgres (ecosystem: pg)
fulfillment_worker/src/index.ts      155   wiring/orchestration
fulfillment_worker/src/loki.ts        35   Sol convention: log push shape
fulfillment_worker/src/metrics.ts     34   Sol convention: metric naming
fulfillment_worker/src/tracing.ts     51   Sol convention: trace propagation
fulfillment_worker/src/wire.ts        51   Sol convention: wire format + decode validation
order_svc/src/index.ts               233   wiring/orchestration
order_svc/src/loki.ts                 37   Sol convention: log push shape
order_svc/src/metrics.ts              23   Sol convention: metric naming
order_svc/src/schemaRegistry.ts      101   Sol convention: schema registry protocol + topic provisioning
order_svc/src/tracing.ts              40   Sol convention: trace propagation
                                      ---
                                      797   total
```

Grouping the "Sol convention" files (schema registry + wire/decode +
tracing + metrics naming + logging, excluding pure wiring/orchestration in
each `index.ts` and the ecosystem `db.ts`): **372 of 797 lines (~47%)**
exist purely to reproduce conventions that an OCaml `sol-svc`/`sol-worker`
app gets from a handful of framework calls (`Kafka_service.register`,
`Sol_obs.of_env`, `Sol_obs.with_span`, `Worker.Make`). The `index.ts`
wiring/orchestration lines aren't pure business logic either — some of
the review-round fixes (the AJV body schema, the drain-timeout race, the
`onResponse` metrics hook, the schema-registry call-order fix, explicit
topic provisioning) are Sol-convention correctness living inline in those
files, so 47% is a floor on the convention share, not a precise split.
For comparison,
`examples/local-demo` (`demo.ml` + `events.ml`, which additionally
includes the HTTP test client and assertion runner this TS port doesn't
have) is 566 lines total — same order of magnitude, but the OCaml side
spends almost none of it on these five concerns because the framework
absorbs them.

## Self-review findings (fixed before handoff)

A single-pass build-it-and-run-it version of this spike had three real bugs
that a skeptical re-read of the diff caught, all now fixed:

1. **Metrics were only recorded on the happy path.** `order_svc`'s
   `/orders` handler incremented `sol_svc_requests_total` inline at the end
   of the handler body — a `producer.send()` failure meant the request was
   never counted at all, not even as a 5xx. Fixed by moving metric
   recording into a Fastify `onResponse` hook that fires for every
   response regardless of outcome, which is also a more faithful port of
   `sol-svc`'s actual behavior — `service.ml`'s dispatch wrapper records
   metrics for every request generically, it isn't something each handler
   opts into. This is itself a data point for the capability table below:
   getting this right requires knowing to reach for a framework-level hook
   rather than inline code, which isn't an obvious instinct.
2. **A Kafka publish failure returned 202 anyway.** The initial port
   mirrored `examples/local-demo/bin/demo.ml`'s handler exactly, which logs
   a publish error to stderr but still returns 202 — a shortcut reasonable
   in a one-shot demo script, not in a service with real callers. Changed
   to let the error propagate (500), matching what `sol-svc`'s contract
   should mean, not what the reference demo script happened to do.
3. **A downstream DB failure was mislabeled and silently swallowed as a
   decode error.** The worker's single catch block covered both "message
   doesn't parse" and "Postgres insert failed" under the same
   `status="decode_error"` metric and the same silent-continue behavior —
   conflating a message that will *never* be valid with a transient infra
   failure that should be retried. Split into two catch blocks
   (`decode_error` vs. `db_error`) and let DB failures rethrow so kafkajs's
   own retry/crash semantics apply. Also added a `consumer.on(CRASH, ...)`
   handler — without it, a worker that exhausts kafkajs's internal retries
   stops consuming *silently*, with no crash and no exit, which is worse
   than either succeeding or dying loudly.

Also removed two dead exports (`decodeWire` and `parseTraceparent` in
`order_svc` — copy-pasted from the worker's equivalent file but never
called, since `order_svc` only ever encodes/produces, never decodes/parses
an inbound trace).

Findings (3) in particular reinforces the recommendation below: getting
Kafka failure-handling semantics (retry vs. reject vs. crash) right by
hand is genuinely easy to get wrong, and is exactly the kind of thing
`kafka_service_retry_topics.ml` exists to solve properly on the OCaml side
— this spike does the bare minimum version of that (crash-on-exhaustion),
not the full forward-retry/DLQ machinery, which is correctly out of scope
here but is real, non-trivial future work if `@sol/kafka` gets built.

## Adversarial review round 1 (fresh external reviewer, fixed)

The fork that built this spike ran a self-review substitute instead of
`/pr`'s real adversarial loop (spawning a fresh subagent from inside a
fork is blocked). The parent session then ran an actual fresh,
zero-context reviewer agent against the diff. It found 10 real issues a
self-review missed, all fixed:

1. **Docker builds weren't reproducible.** Neither `Dockerfile` copied
   `package-lock.json` into the build context, and both used `npm install`
   instead of `npm ci` — every image rebuild re-resolved the dependency
   tree from `^`-ranged `package.json` ranges. Fixed: both stages of both
   Dockerfiles now `COPY package-lock.json` and run `npm ci`.
2. **`pg.Pool` had no `error` listener.** An idle pooled client dying
   underneath it (Postgres restart, failover) would emit an unhandled
   `'error'` event and crash the whole process even with no query in
   flight. Fixed: `pool.on("error", ...)` logs and lets the pool recover.
3. **Schema-registry call order/fatality didn't match the OCaml runtime
   path.** `Kafka_service.register` (`kafka_service.ml:167-177`) calls
   `register_schema` first (fatal on failure) then
   `set_subject_compatibility` second (non-fatal, warn-and-continue) — the
   TS port had the compatibility call first and unguarded, so a registry
   that didn't support that call would kill startup for the wrong reason.
   Fixed: reordered to match, and fixed `registerSchema`'s doc comment,
   which incorrectly claimed to mirror a nonexistent
   compatibility-check-then-register flow (`Schema.check` is a standalone
   CI-gate function in the OCaml code, never composed with registration
   at runtime — verified by reading `kafka_service_schema.ml` directly).
4. **No request-body validation on `POST /orders`.** Malformed bodies
   (wrong types, missing fields) were silently coerced via `?? ""`/`?? 0`
   and published anyway, with the only feedback being a silent drop at the
   worker's decode step — the caller who got a 202 never finds out. Fixed
   using Fastify's built-in JSON-schema (AJV) route validation — an
   ecosystem feature, not new code — returning 400 before the handler runs.
5. **Internal error messages leaked to HTTP callers.** No error handler was
   registered, so Fastify's default serialized `error.message` (e.g. a raw
   Kafka client error) straight into 500 responses. Fixed with a
   `setErrorHandler` that logs the real error server-side and returns a
   generic message for 5xx.
6. **No bounded drain timeout on `order_svc` shutdown.** `sol-svc`'s real
   contract (`service.ml:290-303`) races the drain against
   `drain_timeout_s` (default 30s) and force-cancels rather than hanging
   forever on a client holding a connection open; the TS port awaited
   `app.close()` unconditionally. Fixed with the same race pattern.
7. **Unbounded Prometheus label cardinality on unmatched routes.** A 404
   put the raw, caller-controlled request path into the `route` label —
   under real traffic (scanners, retries with varying paths) that's a
   cardinality bomb. Fixed to use a fixed `"unmatched"` label, matching
   `service.ml:113-114` exactly.
8. **Metric status vocabulary didn't match the real convention.** The real
   worker (`worker.ml:99-163`) uses exactly `{ok, error, retry, ack_failed}`
   on `sol_worker_messages_total` — decode/validation failures never reach
   that counter at all; they're intercepted earlier
   (`kafka_service_intf.ml`'s `wrap_on_decode_error`) and counted on a
   separate `sol_worker_decode_errors_total`. The TS port had invented
   `status="decode_error"`/`status="db_error"` values that would make a
   cross-language Grafana panel disagree between an OCaml and a TS worker.
   Fixed: added a matching `sol_worker_decode_errors_total` counter, and
   relabeled the DB-failure path to `status="error"`.
9. **`traceparent` flags field wasn't W3C-spec-correct.** The producer
   hardcoded the sampled flag to `"01"` regardless of actual sampling
   state; the consumer's parser used `parseInt(flags, 16) || 1`, which
   incorrectly treats a legitimate unsampled trace (`flags=0`) as sampled
   due to JS falsy-zero coercion. Neither manifested in this demo (default
   sampler is always-on), but both are latent spec violations. Fixed both.
10. Noted, not fixed: a JSON payload like `"quantity": 5.0` parses to the
    integer `5` in TS (`JSON.parse` collapses it) but would be rejected by
    OCaml's Yojson-based decoder as `` `Float 5.0 ``, not `` `Int 5 `` — a
    genuine cross-language schema-strictness gap, not a bug in either side
    alone. Documented as a `ponytail:` comment in `wire.ts` rather than
    built around, since fixing it needs a custom JSON parser preserving
    numeric literal formatting — real work a `@sol/kafka` package would
    need to actually decide on, not worth it for a spike.

All fixes verified live against the same real local infra used in the
initial pass (Kafka/Redpanda, Postgres, schema registry) — re-ran the
happy path, two malformed-body cases (400, not 202), a garbage Kafka
message (rejected, counted on `sol_worker_decode_errors_total`, worker
stays alive), the unmatched-route label, and a double-SIGTERM (drains
exactly once, exits cleanly) — all as expected after the fixes.

This review round is itself further evidence for the recommendation
below: an OCaml-native reviewer (or the framework itself) catches classes
of bug — retry/crash semantics, metric-label conventions, propagation
correctness — that are invisible to someone writing idiomatic TypeScript
without cross-referencing the OCaml source line-by-line, which is exactly
the kind of knowledge a `@sol/kafka`/`@sol/obs` package would need to
encode so app authors don't have to rediscover it.

## Adversarial review round 2 (second independent reviewer, fixed)

A second, fully independent reviewer (no context from round 1's findings)
re-read the fixed diff and found 5 further issues round 1 missed —
confirming the two-round structure earns its cost, not just theater:

1. **(High) Kafka topic was never explicitly provisioned.**
   `Kafka_service.register` (`kafka_service.ml:148-165`) calls
   `ensure_topic` (`Kafka.Producer.create_topic` with an explicit
   partition count and `replication_factor:1`) *before* touching the
   schema registry. The TS port skipped this entirely, relying on the
   local Redpanda's auto-create-on-produce default — invisible in this
   demo's environment, but a hard failure
   (`UNKNOWN_TOPIC_OR_PARTITION`) on any cluster with
   `auto.create.topics.enable=false`, which is common in hardened
   production Kafka. Fixed: `order_svc` now calls
   `kafka.admin().createTopics(...)` with the same partition count
   (1, matching `kafka_service_config.ml`'s default) and replication
   factor before registering the schema — verified live by deleting the
   topic, confirming it didn't exist, starting the service, and
   confirming `rpk topic describe` showed it provisioned before any
   message was produced.
2. **(High) The Kafka `CRASH` handler was more aggressive than intended.**
   The handler unconditionally called `process.exit(1)` on any crash. But
   KafkaJS's own crash handling (verified by reading
   `node_modules/kafkajs/src/consumer/index.js` directly, not assumed)
   already self-heals from retriable errors — it sets
   `payload.restart = true` and reschedules itself. The unconditional
   exit was killing the process on crashes KafkaJS was already about to
   recover from on its own, which is the opposite of the stated intent in
   the adjacent comment. Fixed to check `payload.restart` and only exit
   when KafkaJS itself has given up.
3. **(Medium) Schema-registry HTTP calls had no timeout or response-size
   bound**, unlike `Kafka_service_http.http_do` (`kafka_service_http.ml`)
   — the OCaml file these calls are explicitly ported from, which sets a
   10s timeout and a 4MB response cap on every call. A hung registry
   could block `order_svc` startup indefinitely; an unbounded response
   had no memory ceiling. Fixed: added `AbortSignal.timeout(10_000)` and a
   streamed, size-capped body reader matching both OCaml limits exactly.
4. **(Low) `PORT`/`METRICS_PORT` env parsing crashed on a malformed
   value** instead of falling back to the default, unlike `service.ml`'s
   `try int_of_string s with _ -> port` — the exact contract point this
   ticket names by name. Fixed both services with a small `intEnv` helper
   that falls back on a non-finite parse, verified by passing garbage
   values and confirming both fell back to their documented defaults
   (8080, 9090) rather than crashing with a `NaN`-derived listen error.
5. **(Medium, doc-only) The capability table and Recommendation section's
   headline "93%-of-the-pain cluster" claim didn't reconcile with the
   doc's own line counts** under any reasonable denominator. Fixed: the
   claim is now stated as "roughly two-thirds of convention-code lines"
   (372 total convention lines; the schema-registry+wire+tracing cluster
   is ~243 of those), which the numbers actually support, plus a note
   that 5 of the 7 total bugs found across both review rounds landed in
   that same cluster — a second, independent line of evidence for the
   same conclusion, not just a corrected percentage.

All fixes re-verified live: deleted-then-recreated topic provisioning
(explicit `rpk topic describe` check before/after), happy path with the
new topic, and both `PORT`/`METRICS_PORT` fallback paths (each correctly
fell back to its default and failed only on an unrelated pre-existing
port collision in this environment, not a parsing crash).

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

Line counts below are final (post round-2 review fixes, `wc -l` against the
final commit) — a capability table meant to guide a build-or-don't decision
should reflect the actual shipped code, not a pre-fix snapshot.

| Capability | OCaml | TypeScript (raw) | Candidate helper? |
|---|---|---|---|
| HTTP routing | sol-svc | Fastify | No |
| `/healthz` | automatic | ~3 lines manual | No — trivial |
| Prometheus exposition | automatic | prom-client | No |
| Metric naming convention | automatic | ~57 lines manual (both services' metrics.ts) | Maybe — small, but easy to get subtly wrong (wrong label set breaks cross-language dashboards silently — this spike's own round-1 review caught an invented status vocabulary that would have done exactly that) |
| Kafka transport | kafka-eio | KafkaJS | No |
| Kafka topic provisioning | sol-worker (`ensure_topic`) | ~10 lines hand-rolled admin.createTopics call | Maybe — easy to silently skip entirely (this spike did, until round-2 review caught it) since auto-create-on-produce masks the gap in any dev/local setup |
| Schema registry convention | sol-worker | 101 lines hand-rolled HTTP protocol (incl. the 10s timeout / 4MB response cap round-2 review caught was missing) | **Likely** — highest-value target found; requires reading OCaml source to discover it exists at all |
| Confluent wire format | kafka-eio | 51 lines hand-rolled (decode+validate; encode is ~10 lines inside the schema-registry file above) | **Likely** — bundle with the schema registry helper above, same concern |
| Trace propagation (HTTP → Kafka → worker) | sol-obs | 91 lines hand-rolled OTel context bridging | **Likely** — second-highest value; genuinely easy to get subtly wrong (round-1 review caught a non-spec-correct sampled-flag bug in exactly this code) |
| Graceful drain (HTTP) | automatic (bounded by `drain_timeout_s`) | ~15 lines hand-rolled `Promise.race` against a timeout (round-1 review caught the first draft had no bound at all) | Maybe — small, but the *unbounded* version looks correct until a client holds a connection open |
| Graceful drain (Kafka consumer) | automatic | `consumer.disconnect()`, but ~2-3s and order-dependent w.r.t. metrics/db/tracing shutdown | Maybe — small code, but easy to get the shutdown *order* wrong |
| Kafka failure handling (decode-reject vs. infra-retry vs. crash) | sol-worker + kafka_service_retry_topics.ml | hand-rolled, and wrong in two separate ways across this spike's two review rounds (see Self-review findings and round-1/round-2 sections) | **Likely** — bundle with the schema/wire helper; getting retry vs. reject vs. crash semantics right by hand is genuinely error-prone, not busywork |
| PostgreSQL | pg-eio | pg | No |
| Structured logging (formatting) | sol-obs | plain console/fetch sufficed, pino added no value | No |
| Loki push shape/labels | sol-obs | 35-37 lines hand-rolled push API + label convention | Maybe — smaller than schema/tracing, but same "undiscoverable convention" problem |

## Recommendation

Build, in this order, if/when a real TS user justifies it:

1. **`@sol/kafka`** (schema registry + topic provisioning + Confluent wire
   format + trace-header propagation + retry/crash semantics bundled
   together — these showed up as one coherent cluster in this spike, not
   several separate concerns: roughly two-thirds of all convention-code
   lines — 372 of 797 total across both services — and, going by review
   findings alone, five of the seven real bugs found across both
   adversarial review rounds landed somewhere in this cluster). This is
   where an OCaml-only convention is genuinely undiscoverable from
   TypeScript-land without reading OCaml source — and, per round 2's
   finding, easy to silently omit a whole piece of (topic provisioning)
   without any local symptom, since broker auto-create quietly papers
   over the gap in dev.
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
