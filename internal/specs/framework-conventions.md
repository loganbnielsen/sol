# Framework conventions

The cross-language contract every Sol application framework implements
(DEC-022). OCaml and TypeScript are both first-class application languages, and
parity between them is **capability and behavioural parity, not implementation
parity**. The conventions below must hold in every language; the code under them
need not be shared.

This page is an index of the conventions, not a second copy of them. Each row
states the invariant and links the document or code that defines it; the exact
names, values and mechanics live in that definition. When the two disagree, the
linked definition wins, and this page is the one to fix.

- **Where it's written for app authors:** [`docs/reference/`](../../docs/reference/)
  (the runtime and substrate contracts).
- **Where each package specifies its behaviour:** the `.md` beside its `lib/`,
  under [`framework/ocaml/`](../../framework/ocaml/). The TypeScript packages
  live in their own repositories; see [`framework/typescript/`](../../framework/typescript/README.md).
- **Per-language verdicts** (implemented / already equivalent / intentionally
  deferred / not applicable): the complete capability inventory in
  [`typescript-capability-inventory.md`](typescript-capability-inventory.md),
  which covers every row below and names the ticket that owns each gap; a row
  added after that audit states its verdict inline. The
  earlier, demo-scoped snapshot is
  [`2026-09-07_typescript_demo_spike.md`](../pipeline/dogfood/2026-09-07_typescript_demo_spike.md)
  (FEAT-080). Silence is not a verdict. The secret/identity rows are deliberately
  recorded as **in flux** while DEC-029/DEC-062/DEC-063 resolve, not assigned a
  verdict this page would then have to retract.

## The conventions

| Convention | What must hold in every language | Defined in |
| --- | --- | --- |
| Discovery and build | A unit is `app/<domain>/<name>_{svc,worker,fn}/` with a `Dockerfile`. Language is a property of the unit's build, never of its deployment identity or the workspace. | [`runtime.md`](../../docs/reference/runtime.md) § Discovery; DEC-022 clause 7 |
| Lifecycle: `-svc` | Listen on `PORT`. Serve `GET /healthz` (liveness/startup) and `GET /readyz` (readiness; 503 once a stop begins). On `SIGTERM`, turn `/readyz` 503, keep serving for the shutdown delay, stop accepting, then drain in-flight requests up to a bounded timeout. | [`runtime.md`](../../docs/reference/runtime.md) § Runtime health; [`sol-svc.md`](../../framework/ocaml/sol-svc/sol-svc.md) § Built-in Endpoints, § Structured shutdown model |
| Lifecycle: `-worker` | Long-running consumer. Stops cleanly on `SIGTERM`; exposes `GET /metrics` on its metrics port. | [`sol-worker.md`](../../framework/ocaml/sol-worker/sol-worker.md) § Lifecycle, § Signal handling |
| Lifecycle: `-fn` | Runs once and exits: 0 on success, non-zero on error, 130 on `SIGTERM`/`SIGINT`. Metrics are pushed to the Pushgateway, not scraped. | [`sol-fn.md`](../../framework/ocaml/sol-fn/sol-fn.md) § Exit codes, § Behaviour |
| Kafka wire format | Confluent framing: magic byte `0x00`, 4-byte big-endian schema id, JSON payload, so any Confluent-compatible consumer can decode it. | [`kafka-eio-service.md`](../../framework/ocaml/kafka-eio-service/kafka-eio-service.md) § Wire Format |
| Schema registry | One subject per topic; the subject's compatibility is set to `FULL` *before* the declared schema is registered, and failing to set it is an error. Registration is a deployment-lifecycle step, never runtime: producers and consumers only read the registry, and a producer whose declared schema is not registered fails at startup. The workspace exposes the projection through an executable `contract/run` (`--json`/`--check`/`--apply`), whose `--json` is the language-neutral contract object, installed at `/usr/local/bin/contract` in every application image. | [`kafka-eio-service.md`](../../framework/ocaml/kafka-eio-service/kafka-eio-service.md) § Contract registration is a deployment step, § Schema compatibility checking |
| Contract declaration → generated binding | An event's contract facts — topic, partitions, key, schema — are declared once in `events/<team>/sol.toml` and are language-neutral; `[contract] language` selects the binding, whose destination follows the language. OCaml writes `events/<team>/<team>_contract.ml`, TypeScript writes `app/<team>/contract/src/<team>_contract.ts`. The generated binding is checked in and freshness is validated by `sol check`; `sol contract generate` explicitly updates projections, and the app supplies only its value types and codec. | [`kafka-eio-service.md`](../../framework/ocaml/kafka-eio-service/kafka-eio-service.md) § Contract; DEC-065; FEAT-116, FEAT-129 |
| Partitioning and key | An event's contract declares the topic's partition count and its message key, and both are language-neutral obligations: the same resolution holds for an OCaml event module and a TypeScript one. Sol creates the topic with the declared count and never reduces it — registering against a topic that has *more* partitions is an error — and the DLQ topic inherits it. Every record sharing a key is handled by one consumer in publication order, so per-entity ordering survives more than one partition; no key means records spread across partitions and no ordering is claimed. | [`kafka-eio-service.md`](../../framework/ocaml/kafka-eio-service/kafka-eio-service.md) § Message Contract, § Message ordering; DEC-021 § Ordering consequence |
| DLQ | There is no message-level retry: the worker outcome vocabulary is exactly `Ack` \| `Fail`, and a `Fail` leaves the offset uncommitted and stops the consumer. Only framework decode/schema failures are dead-lettered — published raw to `<source>.<canonical-group>.dlq`, keeping the original key and headers, and acknowledged only once that publish succeeds. `<canonical-group>` is the group id sanitized to `[A-Za-z0-9-]` followed by a short hash of the *original* id (BUG-080), so distinct group ids — punctuation variants such as `pay.ments`/`pay_ments`/`pay-ments` included — never share a DLQ topic. Independent retryable work belongs in a Postgres job (`sol-jobs`), enqueued in the transaction that caused it. | [`sol-worker.md`](../../framework/ocaml/sol-worker/sol-worker.md) § Fail stops the consumer, § Error handling; [`kafka-eio-service.md`](../../framework/ocaml/kafka-eio-service/kafka-eio-service.md) § DLQ delivery, § DLQ naming |
| Trace propagation | W3C `traceparent`: read from incoming HTTP headers and Kafka message headers, and written on outgoing peer calls and produced messages. | [`runtime.md`](../../docs/reference/runtime.md) § Synchronous service calls; [`sol-svc.md`](../../framework/ocaml/sol-svc/sol-svc.md) § `Peer`; [`sol-worker.md`](../../framework/ocaml/sol-worker/sol-worker.md) § Module types |
| Operation-level retry | A transient dependency failure is retried at the operation — the dependency call inside the handler — never by re-running the handler or the message. One bounded, jittered policy vocabulary (`base_delay_s`, `max_delay_s`, `max_attempts`, `jitter_ratio`) covers an inline retry and `sol-jobs`; the helper yields to Eio between attempts, exhaustion returns the last error to the caller (who decides what it means), cancellation propagates, and the retried operation must be safe to repeat. | [`sol-retry.md`](../../framework/ocaml/sol-retry/sol-retry.md) § The contract, § One vocabulary; DEC-021 § 2026-09-29 amendment. TypeScript parity is recorded in the [capability inventory](typescript-capability-inventory.md). |
| Metric names and labels | Names follow `sol_<primitive>_…` with a `status` label. The exact names, labels and `status` values are part of the contract and are defined in each package's reference; decode failures have their own counter, `sol_worker_decode_errors_total`. | [`sol-worker.md`](../../framework/ocaml/sol-worker/sol-worker.md) § Metrics; [`sol-svc.md`](../../framework/ocaml/sol-svc/sol-svc.md); [`sol-fn.md`](../../framework/ocaml/sol-fn/sol-fn.md) § Lifecycle; [`sol-jobs.md`](../../framework/ocaml/sol-jobs/sol-jobs.md) § Entrypoint; [`sol-outbox.md`](../../framework/ocaml/sol-outbox/sol-outbox.md) § Public API |
| Config and secrets | Injected as environment variables through the per-service ConfigMap and Secret. The names are the contract (`POSTGRES_URL`, `KAFKA_BROKERS`, `SCHEMA_REGISTRY_URL`, …). `KAFKA_SECURITY_PROTOCOL` is **required**: an absent value is an error, never a default (SEC-007). `SOL_ENV` is for behaviour only. | [`runtime.md`](../../docs/reference/runtime.md) § Config and secret injection, § `SOL_ENV`; `AGENTS.md` § Security on Day 1 |
| Semantic workload identity | Every signal a framework produces carries Sol's semantic workload identity — `workspace`, `env`, `domain`, `service`, `primitive`, `release` — read from the `SOL_*` variables the deployment layer injects and renders as pod labels. Framework instrumentation owns this vocabulary; a collector may add infrastructure identity (`namespace`, `pod`, `node`) but never defines or replaces it. `service` is the workload's bare Kubernetes name, so an app-pushed log or trace is scoped exactly as the collector-promoted ones. | [`observability-design.md`](../../docs/architecture/observability-design.md) § Identity; DEC-064 |
| Job semantics | Postgres-backed, polling claim with `FOR UPDATE SKIP LOCKED`, a lease rather than a held transaction, fenced finalize (`id` and `attempts`), the same backoff formula as the worker, and terminal `completed`/`failed` rows instead of a DLQ. Terminal rows are retained for a retention window, so an `enqueue ?dedupe_key` keeps a re-enqueue a no-op across the Kafka→jobs handoff; otherwise at-least-once, so handlers must be idempotent. | [`sol-jobs.md`](../../framework/ocaml/sol-jobs/sol-jobs.md) § Claim, lease, and retry mechanics; § Deduplication |
| Transactional publication | An event intent commits in the transaction that caused it (`Outbox.publish` takes the transaction handle, so publishing outside one is a type error), and a relay publishes committed intents in per-key order using the ordering token the domain assigned while the key was serialized — never a global sequence, which is how generic commit order would return. The relay removes a row only after the broker acknowledged the write, so a crash between acknowledgement and removal duplicates rather than gaps or inverts: per-key order with at-least-once publication, and consumers must be idempotent. A blocked key holds only its own later events and shows up as publication lag, never as a silent gap. | [`sol-outbox.md`](../../framework/ocaml/sol-outbox/sol-outbox.md) § The contract, § The relay protocol |

## Changing a convention

A change to any row is a change to every language's framework. Per `AGENTS.md`
§ *TypeScript-parity tracking*, the ticket that makes it records the
cross-language consequence in its completion notes: the other language's
verdict, or the ticket that will bring it into line. Update the defining
document first, then this row if its one-line summary changed.
