# Production alert runbooks (OBS-043)

One page per required maturity-A alert condition. Each alert carries its
accountable `owner` and a link to the first-response runbook; the target
declares both, and `sol alert test` proves the route is live. These runbooks are
the *action*, not the proof — HARDEN-002 records the delivered-and-acknowledged
synthetic alert and the game-day results.

The five indicators are deliberately threshold rules, not burn-rate SLOs
(DEC-026 §8; OBS-040's non-goal). Their alert definitions live in
`cli/platform/infra/base/main.tf`'s `local.prometheus_alerting_rules`.

| Indicator | Alert | Signal | First response |
|---|---|---|---|
| Failed rollout | `SolRolloutFailed` | `kube_deployment_status_replicas_available / clamp_min(kube_deployment_spec_replicas, 1) < 1` for 10m | [§ Failed rollout](#failed-rollout) |
| Node loss | `SolNodeNotReady` | `kube_node_status_condition{condition="Ready",status="true"} == 0` for 5m | [§ Node loss](#node-loss) |
| Postgres dependency loss/restore | `SolPostgresUnavailable` | `pg_up == 0` for 5m | [§ Postgres](#postgres-dependency-lossrestore) |
| Kafka lag / broker loss | `SolKafkaConsumerLagHigh`, `SolKafkaBrokerDown` | `redpanda_kafka_consumer_group_lag > 10000` for 10m; `up{job=~".*redpanda.*"} == 0` for 5m | [§ Kafka](#kafka-lag--broker-loss) |
| Telemetry loss | `SolTelemetryTargetDown` | `up{namespace="monitoring"} == 0` for 10m | [§ Telemetry](#telemetry-loss) |

Two of the five (`SolPostgresUnavailable`, the Kafka pair) depend on the target
exposing a scrapeable dependency metric — a Postgres exporter, or Redpanda's own
metrics. Absent that scrape the rule is *silent*, never a false positive; if a
target relies on it, confirm the metric is scraped as part of the pre-pilot
checklist. The managed-RDS path reports through OBS-044's CloudWatch
integration instead.

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
