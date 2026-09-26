# Framework conventions

The cross-language contract every Sol application framework implements
(DEC-022). OCaml and TypeScript are both first-class application languages, and
parity between them is **capability and behavioural parity, not implementation
parity**. The conventions below must hold in every language; the code under them
need not be shared.

This page is an index of the conventions, not a second copy of them. Each row
names the convention and links the document or code that defines it. When the
two disagree, the linked definition wins, and this page is the one to fix.

- **Where it's written for app authors:** [`docs/reference/`](../../docs/reference/)
  (the runtime and substrate contracts).
- **Where each package specifies its behaviour:** the `.md` beside its `lib/`,
  under [`framework/ocaml/`](../../framework/ocaml/). The TypeScript packages
  live in their own repositories; see [`framework/typescript/`](../../framework/typescript/README.md).
- **Per-language verdicts** (implemented / already equivalent / intentionally
  deferred / not applicable): the capability inventory in
  [`2026-09-07_typescript_demo_spike.md`](../pipeline/dogfood/2026-09-07_typescript_demo_spike.md),
  tracked by FEAT-080. Silence is not a verdict.

## The conventions

| Convention | What must hold in every language | Defined in |
| --- | --- | --- |
| Discovery and build | A unit is `app/<domain>/<name>_{svc,worker,fn}/` with a `Dockerfile`. Language is a property of the unit's build, never of its deployment identity or the workspace. | [`runtime.md`](../../docs/reference/runtime.md) § Discovery; DEC-022 clause 7 |
| Lifecycle: `-svc` | Listen on `PORT`. Serve `GET /healthz` (liveness/startup) and `GET /readyz` (readiness; 503 once a stop begins). On `SIGTERM`, turn `/readyz` 503, keep serving for the shutdown delay, stop accepting, then drain in-flight requests up to a bounded timeout. | [`runtime.md`](../../docs/reference/runtime.md) § Runtime health; [`sol-svc.md`](../../framework/ocaml/sol-svc/sol-svc.md) § Built-in Endpoints, § Structured shutdown model |
| Lifecycle: `-worker` | Long-running consumer. Stops cleanly on `SIGTERM`; exposes `GET /metrics` on its metrics port. | [`sol-worker.md`](../../framework/ocaml/sol-worker/sol-worker.md) § Lifecycle, § Signal handling |
| Lifecycle: `-fn` | Runs once and exits: 0 on success, non-zero on error, 130 on `SIGTERM`/`SIGINT`. Metrics are pushed to the Pushgateway, not scraped. | [`sol-fn.md`](../../framework/ocaml/sol-fn/sol-fn.md) § Exit codes, § Behaviour |
| Kafka wire format | Confluent framing: magic byte `0x00`, 4-byte big-endian schema id, JSON payload, so any Confluent-compatible consumer can decode it. | [`kafka-eio-service.md`](../../framework/ocaml/kafka-eio-service/kafka-eio-service.md) § Wire Format |
| Schema registry | One subject per topic; its compatibility is set to `FULL` *before* registering, and failing to set it is an error. A compatibility check treats only 40401/40402 as "not registered yet". | [`kafka-eio-service.md`](../../framework/ocaml/kafka-eio-service/kafka-eio-service.md) § Schema compatibility checking |
| Retry and DLQ | One `retry_policy` vocabulary (`base_delay_s`, `max_delay_s`, `max_attempts`, `jitter_ratio`), with delay `base_delay_s * 2^(attempt-1)`, jittered, then clamped. The strategy is always named explicitly. Durable retry publishes to `<source>.<canonical-group>.retry`, keeping the original key and adding `X-Sol-Attempt`/`X-Sol-Retry-At` headers. On exhaustion it goes to `<source>.<canonical-group>.dlq`. At-least-once, not order-preserving. | [`sol-worker.md`](../../framework/ocaml/sol-worker/sol-worker.md) § Retry strategy; [`kafka-eio-service.md`](../../framework/ocaml/kafka-eio-service/kafka-eio-service.md) § Retry strategy |
| Trace propagation | W3C `traceparent`: read from incoming HTTP headers and Kafka message headers, and written on outgoing peer calls and produced messages. | [`runtime.md`](../../docs/reference/runtime.md) § Synchronous service calls; [`sol-svc.md`](../../framework/ocaml/sol-svc/sol-svc.md) § `Peer`; [`sol-worker.md`](../../framework/ocaml/sol-worker/sol-worker.md) § Module types |
| Metric names and labels | `sol_<primitive>_…` names with a `status` label: `sol_svc_requests_total`, `sol_svc_request_duration_seconds`; `sol_worker_messages_total{status}`, `sol_worker_message_duration_seconds`; `sol_fn_invocations_total{status}`, `sol_fn_duration_seconds`; `sol_jobs_processed_total{status,kind}`, `sol_jobs_job_duration_seconds`. The `status` values are part of the contract. | [`sol-worker.md`](../../framework/ocaml/sol-worker/sol-worker.md) (metric table); [`sol-svc.md`](../../framework/ocaml/sol-svc/sol-svc.md); [`sol-fn.md`](../../framework/ocaml/sol-fn/sol-fn.md) § Lifecycle; [`sol-jobs.md`](../../framework/ocaml/sol-jobs/sol-jobs.md) § Entrypoint |
| Config and secrets | Injected as environment variables through the per-service ConfigMap and Secret. The names are the contract (`POSTGRES_URL`, `KAFKA_BROKERS`, `SCHEMA_REGISTRY_URL`, …). `KAFKA_SECURITY_PROTOCOL` is **required**: an absent value is an error, never a default (SEC-007). `SOL_ENV` is for behaviour only. | [`runtime.md`](../../docs/reference/runtime.md) § Config and secret injection, § `SOL_ENV`; `AGENTS.md` § Security on Day 1 |
| Job semantics | Postgres-backed, polling claim with `FOR UPDATE SKIP LOCKED`, a lease rather than a held transaction, fenced finalize (`id` and `attempts`), the same backoff formula as the worker, and terminal `failed` rows instead of a DLQ. At-least-once, so handlers must be idempotent. | [`sol-jobs.md`](../../framework/ocaml/sol-jobs/sol-jobs.md) § Claim, lease, and retry mechanics |

## Changing a convention

A change to any row is a change to every language's framework. Per `AGENTS.md`
§ *TypeScript-parity tracking*, the ticket that makes it records the
cross-language consequence in its completion notes: the other language's
verdict, or the ticket that will bring it into line. Update the defining
document first, then this row if its one-line summary changed.
