# FND-0035 — A dead Retry_topics relay is reported only when the source consumer exits; health stays green

- **Classification:** `VERIFIED_DEFECT`
- **State:** `FIXED_UNQUALIFIED` (BUG-043, 2026-09-24: a stopped relay closes the source consumer; broker-backed regression + mutation check). TS `@sol-fab/kafka` parity unassessed.
- **First identified:** 2026-09-23, correctness audit
- **Last verified:** 2026-09-23 (`origin/main @ f3e9480b`; kafka-eio 0.3.0)
- **Derived ticket:** `BUG-043`
- **Invariant:** the acknowledgement-ownership invariant (`sol-worker.md:250-256`):
  *"If the required durable transfer fails … the failure is surfaced."* BUG-029's
  requirement: *"either is acceptable, silent stoppage is not."*
- **Evidence class:** `STATIC`

## What is established

`Kafka_service_retry_topics.consume` forks the retry-topic consumer
(`kafka_service_retry_topics.ml:522-556`). When it stops (`Handler_errors` or
`Invalid_config`), the fiber logs `RETRY_RELAY_STOPPED` to stderr, sets
`relay_failure`, and **returns normally**. Nothing cancels the source consumer. The
ref is read only after the source consumer's own `consume_partitioned` returns
(`:610-619`).

A healthy source consumer returns only on SIGTERM, `max_messages`, or its own
exhaustion. Until then the worker keeps consuming, routing `Retry` outcomes to a retry
topic nothing reads, and acking the source offsets. `Worker_health` knows nothing about
the relay, so `/readyz` and `/livez` stay green and Kubernetes never restarts the pod.
The only signal is `relay_failed` on the metric. That fires on publish exhaustion, not
on the relay consumer stopping for other reasons, such as a fatal commit error on the
retry topic.

BUG-029's completion notes record this as a known limitation: *"at the cost of not
being instantaneous for a long-lived healthy source sitting on top of a dead relay —
noted as a possible follow-up."* For a long-running worker, "not instantaneous" means
the failure is surfaced only when the process is next stopped for some other reason.

No message is lost: retry records sit in the retry topic until a restart. The failure
is that retry delivery is silently suspended for an unbounded time while every health
signal says otherwise.

## Impact

Medium. The degraded state BUG-029 set out to remove survives in the steady state.

## Remedy shape

When the relay fiber stops with an error, stop the source consumer too (resolve the
consumer's stop signal, or fail the enclosing switch), so `run` returns `Error` and the
pod restarts. Alternatively, fail `/livez` from the relay's state. Either satisfies
BUG-029's "fail loudly". Test: a relay that stops must make `consume_partitioned`
return `Error` while the source topic is idle.

## Related

BUG-029 (the deferral); BUG-028; AUDIT-080 (worker health).
