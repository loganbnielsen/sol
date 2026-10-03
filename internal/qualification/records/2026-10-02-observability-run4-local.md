# Observability local qualification run 4 — 2026-10-02

The fourth run of the observability workstream
([`../observability/README.md`](../observability/README.md)); the matrix it feeds
is
[`../observability/observability-diagnostic-matrix.md`](../observability/observability-diagnostic-matrix.md).
Runs 1–3 are
[`2026-10-02-observability-local-qualification.md`](2026-10-02-observability-local-qualification.md),
[`2026-10-02-observability-run2-local.md`](2026-10-02-observability-run2-local.md)
and [`2026-10-02-observability-run3-alert-route.md`](2026-10-02-observability-run3-alert-route.md).

Not a provider run. This run re-qualifies the rows whose code changed since run 2
(OB-T3 after `OBS-050`, OB-F3 after `BUG-122`) and induces the two `sol check`
cases run 1 named as unexercised (OB-S5), which found a defect.

## 1. Run identity

| Field | Value | Source |
|---|---|---|
| Sol revision | `6ca2dcce` (`OBS-050/semantic-workload-identity`, PR #961; merged as `49ce3494`) | `git rev-parse HEAD` in the worktree |
| Working tree state | clean | `git status --porcelain` |
| Date | 2026-10-02 (UTC) | |
| Host | `logan`, WSL2, x86_64, Linux 6.6.87.2 | `uname -a` |
| Kubernetes | **none** — Docker unavailable | observed |
| Broker | Redpanda, native, `:9092` / schema registry `:8081` / admin `:9644` | already running |
| Logs / traces / metrics | Loki 3.0.0 `:3100`, Tempo 2.5.0 `:3200`/`:4318`, Prometheus 2.53.0 `:9190`, native | already running from runs 1–3 |
| Dashboard shell | Grafana 11.3.0, native `:3000` | already running |
| Alert delivery | Alertmanager 0.27.0, native `:9093` | already running |

The substrate was left running by runs 1–3 under `/tmp/sol-obs-qual/`; this run
reused it rather than restarting it. The commands below are the ones that
produced each observation.

## 2. OB-T3 — a trace now carries the Sol taxonomy (after OBS-050)

`OBS-050` makes the framework emit the semantic workload identity on every
signal: the manifest injects `SOL_*` into the `<name>-env` ConfigMap and
`Sol_obs.of_env` composes them into the Loki stream labels and the OTLP resource
attributes.

### 2.1 The manifest injects what it renders

A workspace scaffolded by the real binary (`sol new workspace obsdemo`), rendered
by the real `sol up --dry-run` (branch head `6ca2dcce`, merged as `49ce3494`):

```text
$ sol up --dry-run | sed -n '/name: charge-svc-env/,+8p'
  name: charge-svc-env
  ...
  SOL_WORKSPACE: "obsdemo"
  SOL_DOMAIN: "payments"
  SOL_SERVICE: "charge-svc"
  SOL_PRIMITIVE: "svc"
  SOL_RELEASE: "r-b7ea07960ddda458"

$ sol up --dry-run | sed -n '/workspace: "obsdemo"/,+4p'
        workspace: "obsdemo"
        domain: "payments"
        service: "charge-svc"
        primitive: "svc"
        release: "r-b7ea07960ddda458"
```

The pod labels and the `SOL_*` values are byte-identical, and `SOL_SERVICE` is
the bare Kubernetes name (not `<workspace>-<unit>-<primitive>`). No `SOL_ENV`
appears because `sol up` resolves no target — by design.

### 2.2 A real trace carries all six, and its `service` is the workload name

The local demo was run with the identity injected (all six except `SOL_SERVICE`,
so each in-process unit keeps its own `~service`), then Tempo was queried
independently:

```sh
$ SOL_WORKSPACE=obsdemo SOL_ENV=prod SOL_DOMAIN=payments \
  SOL_PRIMITIVE=svc SOL_RELEASE=r-0123456789abcdef \
  dune exec internal/fixtures/local-demo/bin/demo.exe
  ... Trace: Explore > Tempo > 465dc75872a39152fec689f8d91d88b6

$ curl -s localhost:3200/api/traces/465dc75872a39152fec689f8d91d88b6 \
    | jq -c '.batches[] | {span:.scopeSpans[0].spans[0].name,
                           service:(.resource.attributes[]|select(.key=="service.name")|.value.stringValue),
                           attrs:(.resource.attributes|map({(.key):(.value.stringValue//.value.intValue)})|add)}'
{"span":"receive_order","service":"order-svc","attrs":{"service.name":"order-svc","correlation_id":"c-73339a","release":"r-0123456789abcdef","primitive":"svc","domain":"payments","env":"prod","workspace":"obsdemo","service":"order-svc"}}
{"span":"fulfill_order","service":"fulfillment-worker","attrs":{"service.name":"fulfillment-worker","release":"r-0123456789abcdef","primitive":"svc","domain":"payments","env":"prod","workspace":"obsdemo","service":"fulfillment-worker"}}
```

Both spans carry `workspace`/`env`/`domain`/`service`/`primitive`/`release` as
resource attributes, and each span's `service` equals its own `service.name`
(`order-svc` and `fulfillment-worker` — the demo fixture runs two units in one
process, so the shared `SOL_PRIMITIVE=svc` is a fixture artifact; a deployed
worker gets `SOL_PRIMITIVE=worker` in its own ConfigMap).

### 2.3 The taxonomy makes a trace scoped like the same request's logs

Tempo's search now selects by the taxonomy, with a negative control:

```text
{resource.workspace="obsdemo"}            -> 6 traces
{resource.domain="payments"}              -> 6 traces
{resource.primitive="svc"}                -> 6 traces
{resource.release="r-0123456789abcdef"}   -> 6 traces
{resource.env="prod"}                     -> 6 traces
{resource.workspace="no-such-ws"}         -> 0 traces   (negative control)
```

### 2.4 The app-pushed Loki stream carries the same identity

The same demo run pushed its logs directly to Loki; read back independently:

```text
$ curl -s --get localhost:3100/loki/api/v1/query_range \
    --data-urlencode 'query={service="order-svc"}' --data-urlencode "start=..." --data-urlencode "end=..." \
    | jq -c '.data.result[]|.stream'
{"domain":"payments","env":"prod","primitive":"svc","release":"r-0123456789abcdef","service":"order-svc","service_name":"order-svc","workspace":"obsdemo"}

$ for l in workspace env domain primitive release; do curl -s localhost:3100/loki/api/v1/label/$l/values; done
workspace=["obsdemo"]  env=["prod"]  domain=["payments"]  primitive=["svc"]  release=["r-0123456789abcdef"]
```

Before `OBS-050` the app-pushed stream was `{service="obsdemo-charge-svc",
team="payments"}` (run 1 §3/§6) and was not selected by `sol logs`'
`{workspace,domain,service}` query. It is now.

**Verdict:** OB-T3 moves from `DEFECT` to `QUALIFIED (LOCAL)`; OB-L1/OB-L3
re-verified with the app-pushed stream.

## 3. OB-F3 — the corrected Kafka lag rule computes, and agrees with the broker

`BUG-122` replaced `redpanda_kafka_consumer_group_lag` (a metric Redpanda
v26.2.2 does not expose) with a derived expression over the two metrics it does
expose, and fixed the annotation labels. Read from the platform module and
evaluated against the live broker:

```text
$ rg -n 'SolKafkaConsumerLagHigh|consumer_group_lag' platform/cloud/modules/platform/main.tf
806:            alert = "SolKafkaConsumerLagHigh"
807:            expr  = "-sum by (redpanda_group, redpanda_topic) (max by (...) (redpanda_kafka_consumer_group_committed_offset) - on (...) group_left() max by (...) (redpanda_kafka_max_offset)) > 10000"
813:              summary     = "Kafka consumer lag high for group {{ $labels.redpanda_group }}"

$ curl -s --get localhost:9190/api/v1/query --data-urlencode 'query=redpanda_kafka_consumer_group_lag'
-> 0 series    (the old metric still does not exist)

$ curl -s --get localhost:9190/api/v1/query --data-urlencode "query=$EXPR"
-> {"group":"comms-notify-worker","topic":"venus-payments-charges","lag":"5"}
```

Independently, the broker's own lag view:

```text
$ rpk group describe comms-notify-worker
TOTAL-LAG  5
TOPIC                   PARTITION  CURRENT-OFFSET  LOG-START-OFFSET  LOG-END-OFFSET  LAG
venus-payments-charges  0          17              6                 22              5
```

The expression's `5` equals the broker's `LAG 5`, and the annotation now names
`redpanda_group`/`redpanda_topic`, which the series carry.

**Verdict:** OB-F3's lag half moves from `DEFECT` to `QUALIFIED (LOCAL)`. The
broker-down half (`up{job=~".*redpanda.*"} == 0`) remains qualified only
conditional on a Redpanda scrape, which the platform deliberately does not
configure by default.

## 4. OB-S5 — the `sol check` exit vocabulary is wrong for two cases (defect)

Run 1 left "the failing (`exit 2`) and could-not-run (`exit 1`) cases" as the
only unexercised part of OB-S5. Both were induced on a freshly scaffolded
workspace:

```text
$ sol check                          # valid
sol check: ok
exit=0

$ rm app/payments/charge_svc/Dockerfile && sol check
error: app/payments/charge_svc/Dockerfile: Dockerfile is missing
exit=1                               # documented: 2

$ chmod 000 sol.yml && sol check
sol: internal error, uncaught exception:
     Sys_error("/tmp/obs050-qual/obsdemo/sol.yml: Permission denied")
     Raised by primitive operation at Stdlib.open_in_gen ... Called from Sol_cli_config.load ...
exit=125                             # documented: 1 with a clean message

$ sol check --scope nope             # matches nothing
error: sol check: --scope "nope" matches no workload; domains with units: comms
exit=2                               # correct
```

`operations.md` §5 promises 0 / 2 / 1. A failed check returns `reported ()`,
whose code defaults to 1; an unreadable `sol.yml` is an uncaught exception from
`Sol_cli_config.load` (it guards `Sys.file_exists`, not the read).

**Verdict:** OB-S5's valid case stays `QUALIFIED (LOCAL)`; its failing and
could-not-run cases are `DEFECT`. Filed as **BUG-124**
(`READY_FOR_ENGINEERING`); the fix (a `~code:2` for a failed check, and
`Sys_error` captured in `Sol_cli_config.load`) is on
`BUG-124/sol-check-exit-vocabulary`.

## 5. OB-D1 — Grafana serves the taxonomy-labelled data

The native Grafana 11.3.0 provisioned by run 2 still loads the three
datasources and serves queries through its proxy:

```text
$ curl -s localhost:3000/api/datasources | jq -c '[.[]|{name,uid,type}]'
[{"name":"Loki","uid":"loki","type":"loki"},{"name":"Prometheus","uid":"prometheus","type":"prometheus"},{"name":"Tempo","uid":"tempo","type":"tempo"}]

$ curl -s localhost:3000/api/datasources/proxy/uid/loki/loki/api/v1/label/workspace/values
{"data":["obsdemo"]}

$ curl -s -G localhost:3000/api/datasources/proxy/uid/tempo/api/search \
    --data-urlencode 'q={resource.service.name="order-svc"}' --data-urlencode "start=$START" --data-urlencode "end=$END"
-> rootServiceName "order-svc", traceID 465dc75872a39152fec689f8d91d88b6
```

**Verdict:** OB-D1 stays `QUALIFIED (LOCAL)`; the datasource wiring now serves
data whose labels include the taxonomy.

## 6. Row roll-up

| Row | Before this run | After |
|---|---|---|
| OB-T3 trace carries the taxonomy | `DEFECT` (OBS-050) | `QUALIFIED (LOCAL)` — real Tempo trace carries all six; search by each attribute works, negative control 0 |
| OB-L1 exact unit selection | `QUALIFIED (LOCAL)` | re-verified; the app-pushed stream is now selected by the same selector |
| OB-L3 `env` on the log identity | `QUALIFIED` after OBS-049 | re-verified on the app-pushed stream (`env=["prod"]`) |
| OB-F3 Kafka lag alert | `DEFECT` (BUG-122) | `QUALIFIED (LOCAL)` — derived expr equals the broker's LAG; annotations correct |
| OB-F3 broker-down signal | `QUALIFIED (LOCAL)` conditional | unchanged |
| OB-D1 dashboards/datasources | `QUALIFIED (LOCAL)` | re-verified; proxy serves taxonomy-labelled data |
| OB-S5 `sol check` valid | `QUALIFIED (LOCAL)` | unchanged |
| OB-S5 `sol check` failing / could-not-run | `UNQUALIFIED` | `DEFECT` → `BUG-124` |
| OB-T4 traces CLI surface | `UNQUALIFIED` (OBS-045) | decision resolved by DEC-064; `OBS-045` promoted to `READY_FOR_ENGINEERING` with `Depends on: OBS-050` |

## 7. What this run does not establish

- No Kubernetes: workload health, the `kubectl` log fallback, deployed-backend
  URL resolution, panel data under the taxonomy labels at a real scrape, and the
  deploy → rollback → recovery loop remain `NOT REACHED`.
- No cloud target: `self_hosted_durable`, `external`, managed-resource
  dashboards, retention/durability.
- No `SOL_ENV`-bearing pod: the identity was injected manually here, not by a
  deployed manifest; the manifest's values were verified by dry-run, and the
  deployed case is `LIVE`.
- Nothing here is `LIVE`.

## 8. Findings and ledger updates implied

| Finding | Class | State before | State after |
|---|---|---|---|
| `sol check` returns 1 for a failed check and crashes on an unreadable `sol.yml` | LOCAL | not recorded | `BUG-124` filed (`READY_FOR_ENGINEERING`); fix on `BUG-124/sol-check-exit-vocabulary` |
| Traces carry the taxonomy | LOCAL | `DEFECT` (OBS-050) | resolved by `OBS-050` (PR #961) |
| Kafka lag alert references a missing metric | LOCAL | `DEFECT` (BUG-122) | resolved by `BUG-122` (#944), re-verified here |
| OBS-045's `Decision Required` | — | blocked on the trace-identity decision | resolved by `DEC-064`; promoted to `READY_FOR_ENGINEERING` |
