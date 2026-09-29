# Targeted retry-relay poll-interval audit — 2026-09-29

Audited clean canonical `main == origin/main` at `49fb4f7a`. Before filing, `origin/main` advanced to `f63663d4`, which changed only CLI cloud code and tickets (BUG-083/085 implementations, BUG-095 filing). `framework/` and the `kafka-eio` pin (`b2881b31`) are unchanged. No finding was implemented.

## Scope and reconciliation

Today's audits covered cloud inventory (BUG-084–086), scoped deploy, rollback and release identity (BUG-087–090, 092), jobs isolation (BUG-091), ExternalSecret rotation (BUG-093), Terraform state listing (BUG-094) and migration table names (BUG-095). This pass targeted the framework runtime instead: the `kafka-eio-service` `Retry_topics` relay, `kafka-eio`'s `consume_partitioned` and poll fiber, and the `sol-jobs` lease/finalize path.

## BUG-096 — the retry relay's delay wait evicts the consumer from its group

**Status: Open. Severity: High. Category: Runtime Correctness / Data Integrity.**

The relay sleeps inside its handler until `X-Sol-Retry-At` and does not pause the partition. `consume_partitioned`'s routing blocks on a full partition stream, and the poll fiber blocks on the full consumer stream. Polling stops, which defeats BUG-014's keepalive. A delay beyond `max.poll.interval.ms` then evicts the member, relay acks fail, the relay stops, the worker exits, and already-handled records are redelivered. Documented `max_delay_s` values (600s) exceed librdkafka's 300s default. The ticket gives the file/line trace.

Reproduced against a local broker with the pinned `kafka-eio`. A 5-record control kept a 3.0s maximum poll gap. With 600 records, the consumer logged `MAXPOLL ... leaving group`, every ack failed with `Unknown member`, and the group showed 275 records of lag that had already been handled.

## Candidates rejected

- `sol-jobs` handler outliving `lease_s` and running twice: already documented, with fenced finalization and an overrun warning (BUG-050, `sol-jobs.md:105-110`).
- Retry-topic head-of-line and reordering latency: documented and accepted (`kafka-eio-service.md:344-346`). BUG-096 is about group eviction, not latency.
- Retry attempt counting across source/retry stages: traced `process_handler_result` and `decide_action`. `max_attempts = N` gives N handler executions before DLQ, as documented.

## Limits

The reproduction used a scratch program calling `consume_partitioned` directly with a sleeping handler, not a full `sol-worker` binary under `Retry_topics`. The step from a failed relay ack to worker exit is traced from source (`kafka_service_retry_topics.ml:139-151, 503-541`) and was not executed. `max.poll.interval.ms` was reduced to 10s to keep the run short. The `In_memory` variant was not reproduced. Only local scratch Redpanda topics and groups were created. No cluster or cloud state was touched.
