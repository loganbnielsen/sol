# Sol Demo — Friction Log

Observations from writing the e2e demo. Each item is a real moment where the
framework slowed us down or required a workaround. These are the next highest-ROI
improvements before the platform is developer-ready.

---

## 1. `Worker.Make.run` has no `~on_ready` callback  ★★★ high priority

**What happened:** The demo needs to wait for the Kafka consumer to be assigned a
partition before sending orders. `Kafka_service.consume` exposes `?on_ready` for
this. `Worker.Make.run` does not.

**Workaround:** Used `~_consume_loop` (the test injection seam) to bypass the worker's
internal `Kafka_service.consume` call and inject `on_ready` manually.

**Fix:** Add `?on_ready:(unit -> unit)` to `Worker.Make.run` and thread it through to
`Kafka_service.consume`.

---

## 2. `Worker.Make` has no clean `stop` mechanism  ★★ medium priority

**What happened:** In the demo, we needed the worker to stop after N messages.
`Worker.Make` stops only on SIGTERM/SIGINT or when `W.handle` returns `Error`.
Returning `Error "demo complete"` caused the last message to be counted as
`status="error"` in Prometheus — semantically wrong.

**Workaround:** Changed `W.handle` to always return `Ok ()` and relied on the outer
Eio switch cancelling the worker fiber when the demo finishes. Works, but the worker
runs briefly beyond the "done" point and requires understanding Eio switch cancellation.

**Fix options:**
- `?max_messages:int` — stop cleanly after N messages with `status="ok"` for all
- `?stop:bool Atomic.t` — let the user provide the stop flag (same atomic checked
  in the handler) so external code can trigger graceful shutdown without POSIX signals
- `Kafka_consumer.Stop_after_ok` — new handler result variant that processes the
  message successfully then stops

---

## 3. `sol_svc` is `(wrapped true)`, `sol_worker`/`sol_fn` are `(wrapped false)`  ★ low priority

**What happened:** Demo file needed `open Sol_svc` to access `Route`, `Request`,
`Response`, `Service`. But `Worker.Make` is accessed directly (no namespace).
Inconsistency creates confusion: is the pattern `Sol_svc.Route.get` or `Route.get`?

**Fix:** Standardise all three primitives to `(wrapped false)`. The modules become
`Route`, `Request`, `Response`, `Service`, `Worker`, `Fn` — globally accessible like
`Kafka_service`, `Obs`, etc. This is consistent with the existing Kafka and obs packages.

---

## 4. Logging requires `Obs_eio.with_span` boilerplate  ★★ medium priority

**What happened:** To log a single message with context, the pattern is:

```ocaml
let span_ot = Obs_eio.with_context ot [("correlation_id", corr_id)] in
Obs_eio.with_span span_ot "receive_order" (fun span ->
  Obs_eio.log span Info ~fields:[("order_id", "x")] "order received"
);
```

For application code this is three lines per log statement. Users coming from
`Printf.printf` or a logger like `logs` expect a single-line API.

**Fix:** Add a convenience wrapper:

```ocaml
val log_info : t -> ?fields:(string * string) list -> string -> unit
(* Equivalent to: with_span t "<auto>" (fun s -> log s Info ~fields msg) *)
```

This doesn't need a span name for simple log lines — the span name can default to
the message string or a constant like `"log"`.

---

## 5. Correlation ID is manual end-to-end  ★★ medium priority

**What happened:** To propagate `correlation_id` from HTTP header → Kafka message →
worker logs, the user must:
1. Extract it from `Request.header` in the svc handler
2. Embed it as a field in the Kafka message (`Events.OrderPlaced.correlation_id`)
3. Re-extract it from `msg.correlation_id` in `W.handle`
4. Create a new `Obs_eio.with_context` span with it in both places

**No framework help at any step.** This is three separate manual steps and one of the
most important things Observability should handle automatically.

**Fix:** W3C `traceparent` propagation over Kafka headers:
- `Kafka_service.publish` accepts `?traceparent:string` and writes it as a Kafka
  message header (not payload — no schema change required)
- `Kafka_service.consume`'s handler receives a `context : Obs_trace.t option` alongside
  the message, extracted from the header
- `Worker.Make` automatically creates `Obs_eio.with_context ot [("trace_id", ...)]` using it

This removes all three manual steps. The event contract is kept clean (no
observability fields in the schema).

---

## 6. Two Kafka credentials (admin API + schema registry) add startup friction  ★ low priority

**What happened:** `Kafka_service.config` requires `schema_registry_url` and `admin_url`
separately. For local development, users need to know both Redpanda admin port (9644) and
schema registry port (8081) in addition to the Kafka broker port (9092).

**Fix:** `Kafka_service.config_of_env ()` helper that reads `KAFKA_BROKERS`,
`SCHEMA_REGISTRY_URL`, `REDPANDA_ADMIN_URL` from the environment with sensible defaults,
reducing config boilerplate from 6 lines to 1.

---

## 7. `Obs_eio.log` requires a span, not a handle  ★★ medium priority  

**What happened:** `Obs_eio.log : span -> level -> ...` takes a `span` obtained from
`Obs_eio.with_span`. Users who just want to log without an explicit span have to wrap every
log call in `with_span`. This leaks distributed tracing concepts into code that doesn't
need them.

**Related to:** Friction item #4 (logging boilerplate).

**Fix:** Add `Obs_eio.log_t : t -> level -> ?fields:... -> string -> unit` that logs directly
from an `Obs_eio.t` handle without requiring an explicit span. Internally, it creates an
anonymous span that completes immediately.

---

## Summary

| # | Item | Priority | Effort |
|---|------|----------|--------|
| 1 | Worker.Make needs `~on_ready` | High | Small |
| 2 | Worker.Make needs a clean stop mechanism | Medium | Medium |
| 3 | Primitive `(wrapped)` inconsistency | Low | Small |
| 4 | Logging boilerplate (3 lines per log) | Medium | Small |
| 5 | Correlation ID propagation is manual | Medium | Medium |
| 6 | Two Kafka credentials for local dev | Low | Small |
| 7 | `Obs_eio.log` requires a span, not a handle | Medium | Small |
