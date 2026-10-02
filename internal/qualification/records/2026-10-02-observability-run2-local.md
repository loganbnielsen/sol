# Observability local qualification run 2 — 2026-10-02

The second run of the observability workstream
([`../observability/README.md`](../observability/README.md)); the matrix it feeds
is
[`../observability/observability-diagnostic-matrix.md`](../observability/observability-diagnostic-matrix.md).
Run 1 is
[`2026-10-02-observability-local-qualification.md`](2026-10-02-observability-local-qualification.md).

Not a provider run. This run closes the cheapest open rows: the decode-error
path, FND-0027, the Grafana dashboards, and the Kafka alert signals. It also
resolves the trace-identity contract as a decision (`DEC-064`).

## 1. Run identity

| Field | Value | Source |
|---|---|---|
| Sol revision | `1eace495` (`main`) | `git rev-parse HEAD` |
| Working tree state | clean | `git status --porcelain` |
| Date | 2026-10-02 (UTC; the machine's local clock read 2026-10-03) | `date -u` |
| Kubernetes | **none** — Docker unavailable, so `k3d`/`k3s` cannot run | observed |
| Broker | Redpanda **v26.2.2** (`rpk version`), native | `rpk version` |
| Logs / traces / metrics | Loki 3.0.0, Tempo 2.5.0, Prometheus 2.53.0, native binaries | started this run |
| Dashboard shell | Grafana **11.3.0**, native (the repo pins `grafana/grafana:11.3.0` in Docker) | started this run |
| Workload under test | `internal/fixtures/venus`' `comms/notify_worker` (`~service:"notify-worker"`, group `comms-notify-worker`, topic `venus-payments-charges`) | real repo fixture |

## 2. OB-F2 — decode error → structured diagnostic → DLQ → offset ordering

### 2.1 Induce

The venus `notify_worker` was run standalone (no `POSTGRES_URL`), exposing
`/metrics` on `:9090` with `KAFKA_*`, `LOKI_URL` and `TEMPO_URL` set. One
undecodable record was produced to its source topic:

```sh
$ echo 'garbage-not-confluent-payload' | rpk topic produce venus-payments-charges -k probe-key
Produced to partition 0 at offset 15 with timestamp 1790980854081.
```

### 2.2 The structured diagnostic (stdout and Loki)

Worker stderr:

```text
SPAN  svc=notify-worker name=log trace=2ec98b58ff2018c018d8dbdcde77eca0 span=a1e258e23a63d95a status=ok dur=0.00ms | log.level=error log.msg=sol-worker: decode error, routing message to the DLQ error=wire format: invalid magic byte raw_bytes_len=29 topic=venus-payments-charges
sol-worker: DECODE_ERROR to_dlq=true error="wire format: invalid magic byte"
```

The same line, read back from Loki (explicit time window — Loki's default
query window does not reach an hour-old line):

```text
$ curl --get http://localhost:3100/loki/api/v1/query_range \
    --data-urlencode 'query={service="notify-worker"}' --data-urlencode "start=<3h ago>" …
level=error msg="sol-worker: decode error, routing message to the DLQ" span=log error="wire format: invalid magic byte" raw_bytes_len=29 topic=venus-payments-charges trace_id=2ec98b58ff2018c018d8dbdcde77eca0 span_id=a1e258e23a63d95a
```

The line names the error, the raw length, the topic, and carries the trace id.

### 2.3 The metric

```text
$ curl -s http://localhost:9090/metrics | grep sol_worker_decode_errors_total
sol_worker_decode_errors_total 1
```

After a second undecodable record: `sol_worker_decode_errors_total 2`.
`sol_worker_messages_total` gained **no** sample — an undecodable record never
reaches the handler and is counted on the decode counter, not as a message
(`sol-worker.md`).

Prometheus, scraping the worker's `/metrics`, held the series
`sol_worker_decode_errors_total{instance="localhost:9090",job="sol-workloads"} 1`.

### 2.4 The DLQ record, independently read back

```text
$ rpk topic consume venus-payments-charges.comms-notify-worker-8199500a4289.dlq -p 1 -o start -n 1
key=     probe-key
value=   garbage-not-confluent-payload
partition= 1
offset=  0
headers= [{"key": "X-Sol-Decode-Error", "value": "wire format: invalid magic byte"},
          {"key": "X-Sol-Origin-Group", "value": "comms-notify-worker"}]
```

The original key and raw bytes are preserved; both diagnostic headers are
present. (The DLQ topic is `<source>.<canonical-group>.dlq` as documented.)

### 2.5 Offset ordering

`rpk group describe comms-notify-worker` before the record:

```text
venus-payments-charges  0  15  6  15  0
```

after:

```text
venus-payments-charges  0  16  6  16  0
```

So the source offset advanced past the bad record. The order is publish-then-ack
in the code (`Kafka_service_dlq.route_decode_error` publishes to the DLQ and only
then calls `ack`), and `on_decode_error` returns `Consumer.Error ke` if that
publish fails — which stops the consumer without acking. **The publish-failure
branch itself was not induced** (it needs a DLQ the producer cannot write, which
this broker has no ACL-enabled way to arrange); the success path is what was
observed.

**Verdict:** OB-F2 `QUALIFIED (LOCAL)` for the default `Route_to_dlq` path
(diagnostic, metric, DLQ contents, ordering); the `Ack_and_drop` alternative is
already covered by the repository's Kafka integration suite
(`test_kafka_service_integration.ml`), not re-run here; the publish-failure
branch is `NOT REACHED`.

## 3. FND-0027 — is a malformed backend response silently dropped?

FND-0027 records an *older* implementation that filtered malformed Loki values
with `List.filter_map … | _ -> None` and returned `Ok`, silently truncating. The
current parser (`cli/lib/local/sol_cli_loki.ml`) uses `Sol_cli_result.map_list`,
which aborts on the first malformed value. Induced against a stub returning three
shapes:

```sh
$ sol local logs --scope payments/charge_svc --no-follow --loki-base-url http://127.0.0.1:3301
(couldn't reach http://127.0.0.1:3301: Loki response: a value is not a [timestamp, line] pair. Falling back to Kubernetes logs for charge_svc...)

$ … 3302   # a stream with no "values" field
(couldn't reach http://127.0.0.1:3302: Loki response: values is missing. Falling back to Kubernetes logs for charge_svc...)

$ … 3303   # one good stream and one malformed stream
(couldn't reach http://127.0.0.1:3303: Loki response: a value is not a [timestamp, line] pair. Falling back to Kubernetes logs for charge_svc...)
```

Every case is rejected with the reason and degrades explicitly; **no partial
result is returned, and nothing is silently dropped**. FND-0027's premise is
stale.

**One new observation:** the message says "couldn't reach …" for a response the
command *did* reach — a malformed body is reported as a transport failure. Low
severity; recorded, and wired into the follow-up below.

**Verdict:** OB-L4 `QUALIFIED (LOCAL)`; FND-0027 `SUPERSEDED`.

## 4. OB-D1 — Grafana loads the provisioned dashboards and datasources

A native Grafana 11.3.0 was started with file provisioning:

- datasources: `Loki` (`uid=loki`, with the `trace_id=([0-9a-f]{32})` derived
  field pointing at `uid=tempo`), `Tempo` (`uid=tempo`), `Prometheus`
  (`uid=prometheus`);
- dashboards: the five files under `platform/shared/observability/dashboards/`
  plus the local demo dashboard.

Observed:

```text
$ curl -s localhost:3000/api/health                     → 200
$ curl -s localhost:3000/api/datasources | jq -c '[.[]|{name,uid,type}]'
[{"name":"Loki","uid":"loki","type":"loki"},{"name":"Prometheus","uid":"prometheus","type":"prometheus"},{"name":"Tempo","uid":"tempo","type":"tempo"}]
$ curl -s 'localhost:3000/api/search?type=dash-db' | jq -c '[.[]|.uid]'
["sol-demo-overview","sol-domain-overview","sol-release-timeline","sol-service-template","sol-target-infrastructure","sol-workspace-overview"]
```

The loaded dashboards' uids and template variables are exactly what `sol open`
links name (`sol-workspace-overview` + `workspace`; `sol-service-template` +
`workspace`/`domain`/`service`). Datasource queries executed through Grafana's
proxy returned real data:

```text
Loki   /api/datasources/proxy/uid/loki/loki/api/v1/label/service/values
       → ["fulfillment-worker","manual-probe","notify-worker","order-svc"]
Prom   /api/datasources/proxy/uid/prometheus/api/v1/query?query=up
       → 2 series (both targets up)
Tempo  /api/datasources/proxy/uid/tempo/api/search?q={resource.service.name="order-svc"}
       → 3 traces (with an explicit start/end range; without one the proxy returned none)
```

**Verdict:** OB-D1 moves from `QUALIFIED (MECHANISM)` to `QUALIFIED (LOCAL)`:
Grafana itself accepts the definitions, wires the datasources, and serves
queries. What remains unqualified is panel *data* under the taxonomy labels,
which needs a cluster whose scrape promotes the pod labels (the local static
scrape does not).

## 5. OB-F3 — the Kafka lag alert references a metric Redpanda does not expose

The alert `SolKafkaConsumerLagHigh` uses
`redpanda_kafka_consumer_group_lag > 10000`. Against the real broker:

```text
$ curl -s localhost:9644/public_metrics | grep -c '^redpanda_kafka_consumer_group_lag'
0
$ curl -s localhost:9644/public_metrics | grep '^# HELP' | grep -i kafka | awk '{print $3}'
redpanda_kafka_consumer_group_committed_offset
redpanda_kafka_consumer_group_consumers
redpanda_kafka_consumer_group_topics
redpanda_kafka_max_offset
… (no lag gauge)
```

Neither `/public_metrics` (146 families) nor the internal `/metrics` exposes a
consumer-group lag metric on Redpanda v26.2.2. A Prometheus scrape of the broker
confirms the rule can never fire:

```text
$ curl -s --get localhost:9190/api/v1/query --data-urlencode 'query=redpanda_kafka_consumer_group_lag'
→ 0 series
$ curl -s --get localhost:9190/api/v1/query --data-urlencode 'query=up{job=~".*redpanda.*"}'
→ up{job="redpanda"} = 1
```

A lag **can** be derived from the two metrics Redpanda does expose, and the
derivation was validated against the broker's own lag report:

```text
lag = -sum by (redpanda_group, redpanda_topic) (
        max by (redpanda_group, redpanda_topic, redpanda_partition) (redpanda_kafka_consumer_group_committed_offset)
        - on (redpanda_topic, redpanda_partition) group_left()
          max by (redpanda_topic, redpanda_partition) (redpanda_kafka_max_offset))

live group, caught up      → 0     (broker: LAG 0)
after producing 5 records  → 5     (broker: LAG 5)
```

A second defect sits in the same rule: its annotations render
`{{ $labels.group }}` and `{{ $labels.topic }}`, but the metric's labels are
`redpanda_group` and `redpanda_topic`, so a firing alert would name nothing.

`SolKafkaBrokerDown`'s `up{job=~".*redpanda.*"} == 0` is sound **when a Redpanda
scrape exists**; the platform does not configure one by default, which
`observability-backends.md` already documents as the reason the pair is silent.

**Verdict:** OB-F3 `DEFECT` — filed as `BUG-122`.

## 6. Row roll-up

| Row | Required class | Result | Evidence |
|---|---|---|---|
| OB-F2 decode → diagnostic → DLQ → ordering | LOCAL | PASS (default path) | §2 |
| OB-F2 `Ack_and_drop` | LOCAL | NOT RE-RUN (integration suite covers it) | §2.5 |
| OB-F2 DLQ-publish failure branch | LOCAL | NOT REACHED | §2.5 |
| OB-L4/FND-0027 malformed response | LOCAL | PASS; finding `SUPERSEDED` | §3 |
| OB-D1 Grafana dashboards/datasources | LOCAL | PASS | §4 |
| OB-D1 panel data under taxonomy | LOCAL (needs scrape labels) | NOT REACHED | §4 |
| OB-F3 Kafka lag alert | LOCAL | FAIL → `BUG-122` | §5 |
| OB-F3 broker-down signal | LOCAL | PASS (with a scrape) | §5 |
| OB-T3 trace identity | decision | `DEC-064` recorded; `OBS-050` READY | `DEC-064` |

## 7. What this run does not establish

- No Kubernetes: the `kubectl` log fallback, workload health, deployed-backend
  URL resolution, and the deploy → rollback → recovery loop remain `NOT REACHED`.
- No Alertmanager: alert firing and delivery are still `BLOCKED`.
- No cloud target: `self_hosted_durable`, `external`, and managed-resource
  dashboards remain `UNQUALIFIED`.
- The DLQ-publish failure branch was not induced.
- Nothing here is `LIVE`.

## 8. Findings and ledger updates implied

| Finding | Class | State before | State after |
|---|---|---|---|
| `SolKafkaConsumerLagHigh` references a metric Redpanda does not expose; its annotations name labels that do not exist | LOCAL | not recorded | `BUG-122` filed (`READY_FOR_ENGINEERING`) |
| FND-0027's silent-drop premise | LOCAL | `OPEN` | `SUPERSEDED` |
| Trace resource identity | decision | `OBS-050` `BACKLOG` with a decision | `DEC-064` decided; `OBS-050` `READY_FOR_ENGINEERING` |
| A malformed backend response is reported as "couldn't reach" | LOCAL | not recorded | `BUG-123` filed (`READY_FOR_ENGINEERING`) |
