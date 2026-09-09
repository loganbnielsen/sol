---
id: FEAT-035
type: feature
severity: low
source: FEAT-033 findings (project/dogfood/2026-09-07_typescript_demo_spike.md) — headline recommendation of that spike, second priority after FEAT-034
---

**Depends on:** FEAT-033 (done — evidence base). Not on FEAT-034 — this is deliberately Kafka-agnostic (see below), so it doesn't need to wait for the Kafka package, though in practice they'd likely be built together since FEAT-034 depends on the tracing/metrics primitives this ticket would own.

Build `@sol/obs`, a small TypeScript package encoding Sol's observability *naming and shape* conventions — metric names/labels, Loki push shape — once a real external TypeScript user needs cross-language dashboard/log consistency with Sol's OCaml services.

## Unblocked (2026-09-08)

Unblocked alongside FEAT-034 — see its ticket for the current rationale (the TS demo is now planned as a framework showcase, not gated on organic external adoption). Moved to `READY_FOR_ENGINEERING`.

**Original blocking rationale (superseded, kept for context):** Same demand signal as FEAT-034 — no real external TS user had hit the OCaml wall yet. See [[project_ocaml_only_risk]].

## Why this is a separate package from `@sol/kafka`

The conventions here aren't Kafka-specific — an HTTP request into a hypothetical TS `-svc` needs the same metric-naming convention and the same Loki log shape that a Kafka-consuming worker does. Bundling this into `@sol/kafka` would mean a future `@sol/http` reinventing the same logging/metrics glue independently. Ecosystem libraries (`prom-client`, any structured logger) provide the *mechanism*; only Sol has an opinion on the *shape*, and only Sol's opinion needs to be shared.

## Scope, derived from FEAT-033's findings

1. **Metric naming convention.** `prom-client` (or any Prometheus client) has zero opinion on what a metric should be called — it will happily let you name it anything. Sol's actual vocabulary lives only in OCaml source: `framework/sol-worker/lib/worker.ml:84-89` defines `sol_worker_messages_total{status}` with status values in exactly `{ok, error, retry, ack_failed}`, and `sol_worker_message_duration_seconds`; decode/validation failures are *not* a `messages_total` status at all — they're intercepted before the handler runs (`kafka_service_intf.ml`'s `wrap_on_decode_error`) and counted on a separate `sol_worker_decode_errors_total`. FEAT-033's TS port invented `status="decode_error"`/`status="db_error"` label values on its first draft — round-1 adversarial review caught that a cross-language Grafana panel keyed on this metric's `status` label would disagree between an OCaml worker and a TS one. `framework/sol-svc/lib/service.ml:216-227` defines the HTTP-side equivalent: `sol_svc_requests_total{method,route,status_class}` and `sol_svc_request_duration_seconds{method,route}`, with a fixed `"unmatched"` route label for any request that never matched a route (`service.ml:113-114`) — FEAT-033's first draft put the raw, caller-controlled request path into that label instead, an unbounded-cardinality bug caught by the same review round. `@sol/obs` should export these as named constants/helpers, not leave every TS author to retype the string literals correctly from memory.
2. **W3C `traceparent` propagation helpers.** Whether this lives here or in `@sol/kafka` (FEAT-034) is a build-time call, but the underlying glue — OpenTelemetry has no official Kafka carrier, so "write a span's context as a `traceparent` header string" and "parse an inbound `traceparent` back into a remote parent context" have to be hand-written regardless of transport — is Sol-specific either way. FEAT-033's implementation (`examples/pluto/app/demo_ts/order_svc/src/tracing.ts`, `fulfillment_worker/src/tracing.ts`) is a working reference; it needed two rounds of review to get the flags-byte handling actually W3C-spec-correct (hardcoded `"01"` ignoring real sampled state; `parseInt(flags,16) || 1` incorrectly treating a legitimate unsampled trace as sampled due to JS falsy-zero coercion).
3. **Loki push shape.** `examples/pluto/app/demo_ts/{order_svc,fulfillment_worker}/src/loki.ts` (35-37 lines each) hand-roll the push API and structured-log-field convention Sol expects. No review round found a bug here, but it's still convention duplicated per-service today with no shared source of truth.

## Non-goals

- Not a logging *library* — FEAT-033 explicitly found that reaching for `pino` added no value (see that ticket's findings doc, "Friction log" section: "the entire interesting problem is the Loki push shape/labels... not log formatting/performance"). Don't build or require a structured-logging dependency; own the Loki push shape and metric naming, let the TS author's logger of choice (or none) handle formatting.
- Not `@sol/kafka` (FEAT-034) or `@sol/http`/`@sol/worker` (FEAT-036).
