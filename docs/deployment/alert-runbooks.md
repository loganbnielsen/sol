# Production alert runbooks (OBS-043)

One page per required maturity-A alert condition. Each alert carries its
accountable `owner` and a link to the first-response runbook; the target
declares both, and `sol alert test` proves the route is live. These runbooks are
the *action*, not the proof — HARDEN-002 records the delivered-and-acknowledged
synthetic alert and the game-day results.

The indicators are deliberately threshold rules, not burn-rate SLOs
(DEC-026 §8; OBS-040's non-goal). Their alert definitions live in
`cli/platform/infra/base/main.tf`'s `local.prometheus_alerting_rules`.

| Indicator | Alert | Signal | First response |
|---|---|---|---|
| Failed rollout | `SolRolloutFailed` | `kube_deployment_status_replicas_available / clamp_min(kube_deployment_spec_replicas, 1) < 1` for 10m | [§ Failed rollout](#failed-rollout) |
| Node loss | `SolNodeNotReady` | `kube_node_status_condition{condition="Ready",status="true"} == 0` for 5m | [§ Node loss](#node-loss) |
| Postgres dependency loss/restore | `SolPostgresUnavailable` | `pg_up == 0` for 5m | [§ Postgres](#postgres-dependency-lossrestore) |
| Kafka lag / broker loss | `SolKafkaConsumerLagHigh`, `SolKafkaBrokerDown` | `redpanda_kafka_consumer_group_lag > 10000` for 10m; `up{job=~".*redpanda.*"} == 0` for 5m | [§ Kafka](#kafka-lag--broker-loss) |
| Message drop / diversion (OBS-047) | `SolWorkerDecodeDrops`, `SolWorkerRelayPublishFailed`, `SolWorkerDeadLetterInflow` | `increase(sol_worker_decode_errors_total[5m]) > 0`; `sol_worker_messages_total{status="relay_failed"} > 0` (since the pod started); `rate(sol_worker_messages_total{status="dead_letter"}[10m]) > 0` for 15m | [§ Message drop](#message-drop--diversion) |
| Telemetry loss | `SolTelemetryTargetDown` | `up{namespace="monitoring"} == 0` for 10m | [§ Telemetry](#telemetry-loss) |

Two of the five (`SolPostgresUnavailable`, the Kafka pair) depend on the target
exposing a scrapeable dependency metric — a Postgres exporter, or Redpanda's own
metrics. Absent that scrape the rule is *silent*, never a false positive; if a
target relies on it, confirm the metric is scraped as part of the pre-pilot
checklist. The managed-RDS path reports through OBS-044's CloudWatch
integration instead.

The message-drop rules read sol-worker's own metrics, which exist only when the
worker runs with observability (`?ot`, as the scaffolded worker does). A worker
built without it is invisible to them: silent, never a false positive.

---

## Failed rollout

**Meaning.** A Deployment has had fewer available replicas than desired for 10
minutes: the new release is not becoming ready. This is the signal DEC-026 §3's
`workload-availability` work relies on.

**First response.**
1. `sol status` (once AUDIT-069 wires the drift check) or
   `kubectl -n <workspace>-<domain> describe deploy <service>` — read the
   `Progressing`/`Available` conditions.
2. `kubectl -n <namespace> get events --sort-by=.lastTimestamp | tail`.
3. `sol deployments` — confirm which release/attempt is in flight.
4. If the new release is bad: `sol rollback <service>` back to the last good
   recorded digest (DEC-027: the failed attempt never advanced the pointer, so
   the prior release is still authoritative).

## Node loss

**Meaning.** A node is NotReady. Workloads on it are being rescheduled.

**First response.**
1. `kubectl get nodes` — one node down is the `node-failure-tolerant` tier's
   design case; more than one is outside the profile.
2. Confirm the affected `node-failure-tolerant` workloads kept their
   concurrently-ready replicas (`kubectl -n <ns> get pods -o wide`).
3. Check the capacity-restoration bound: replacement capacity should return
   within the §3 target (5 minutes) given the fixed headroom.
4. If the node does not return, replace it through the provisioning identity
   (AUDIT-072) — never the cluster-creator credential.

## Postgres dependency loss/restore

**Meaning.** The monitored Postgres target is down. Application writes may be
failing; the `SolPostgresUnavailable` rule is `critical`.

**First response.**
1. `application-data-recovery.md` is the authoritative procedure: backup,
   restore, failover and integrity verification.
2. Confirm automatic failover completed (Multi-AZ) and measure the RTO against
   DEC-026 §5's bound.
3. For logical loss, restore via PITR into a clean target and verify at the
   *application* level, not just "provider job completed".
4. Record the measured RPO/RTO for HARDEN-002.

## Kafka lag / broker loss

**Meaning.** Either a consumer group is falling behind
(`SolKafkaConsumerLagHigh`) or a broker is unreachable
(`SolKafkaBrokerDown`).

**First response.**
1. One broker down is within the `single-broker-loss` durability contract
   (RF≥3, `acks=all`, write caching disabled); confirm leader re-election
   completed and consumers resumed within the §5 target (60 seconds).
2. More than one broker down is an explicit exclusion — escalate and treat as
   incident, not profile behaviour.
3. For lag: check consumer health (`sol logs`) and whether a rollout is
   blocking consumers; scale only if the declared replica bounds allow.
4. Never disable `SOL_KAFKA_DURABILITY` to "work around" lag: that trades
   durability for throughput outside the profile's contract.

## Message drop / diversion

**Meaning.** A worker is not processing messages it received. Consumer lag cannot
show this: a worker that acks and drops keeps lag at zero.

- `SolWorkerDecodeDrops` (critical): messages on the source topic could not be
  decoded. Under `Retry_topics` (default `decode_error_policy = Route_to_dlq`,
  BUG-051) they were diverted, raw, to the group's DLQ with `X-Sol-Decode-Error`.
  Under `In_memory`, a plain `Make` worker, or an explicit `Ack_and_drop`, they
  were **acked and dropped**, and the input is gone from this consumer group. The
  usual cause is a producer deploying a schema this consumer cannot read.
- `SolWorkerRelayPublishFailed` (critical): publishing to the group's retry or DLQ
  topic failed after in-process retries, at least once since the pod started. Those
  records stay unacknowledged, but retry delivery is not progressing (BUG-029).
- `SolWorkerDeadLetterInflow` (warning): the handler has been dead-lettering work
  for 15 minutes, meaning a dependency is failing or a deploy is rejecting valid
  input.

**First response.**
1. Decode drops: find the producer change (the worker's error log names the
   decode error and topic). Roll back the producer, or deploy a consumer that reads
   the new schema. Dead-lettered records are in `<topic>.<group>.dlq`; replay them
   once the consumer can read them. Dropped messages are still in the source topic
   until retention expires, so replay is possible by resetting the group's offset.
   Plan it before retention runs out.
2. Relay failures: check broker health and ACLs/quotas on `<topic>.<group>.retry`
   and `.dlq`. A failed publish stops the worker, whether it came from the
   *source* consumer or the *retry relay* (the relay closes the source consumer,
   BUG-043), so the pod restarts. A restart resumes from the last committed offset
   and clears this alert.
3. DLQ inflow: inspect the DLQ records (`X-Sol-Origin-Group`,
   `X-Sol-Decode-Error`) and the handler's `Dead_letter` reasons. Fix the cause,
   then replay the DLQ deliberately.

## Telemetry loss

**Meaning.** A monitoring-namespace scrape target is down. DEC-026 §5 makes
telemetry the deliberately weakest contract: this is a **diagnosability
degradation**, explicitly *not* a business-data durability event.

**First response.**
1. Identify the target (`{{ $labels.job }}` / `{{ $labels.instance }}`) and
   restart/replace it.
2. Note the window in which logs/metrics/traces are incomplete so downstream
   investigations know what is missing.
3. Do not treat telemetry loss as a release-blocking data incident; it does not
   share Postgres/Kafka's RPO/RTO.
