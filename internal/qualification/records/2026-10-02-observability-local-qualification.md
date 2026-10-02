# Observability local qualification run — 2026-10-02

Not a provider run. This record exercises the framework's observability runtime
and the `sol` diagnostic surfaces on one host against **real** backends, because
the deployed/Kubernetes half of the contract cannot be reached here. It is the
first record of the observability workstream
([`../observability/README.md`](../observability/README.md)); the matrix it
feeds is
[`../observability/observability-diagnostic-matrix.md`](../observability/observability-diagnostic-matrix.md).

## 1. Run identity

| Field | Value | Source |
|---|---|---|
| Sol revision | `2a2c5a7c` | `git rev-parse HEAD` (`main`, canonical checkout) |
| Working tree state | clean (`git status --porcelain` empty) | before and after the run |
| Date | 2026-10-02 | |
| Host | `logan`, WSL2, x86_64, Linux 6.6.87.2 | `uname -a` |
| Kubernetes | **none** — Docker is unavailable in this WSL distribution, so `k3d`/`k3s` cannot run (`docker ps` → "could not be found in this WSL 2 distro") | observed |
| Broker | Redpanda, native, `:9092` / schema registry `:8081` / admin `:9644` | already running |
| Logs backend | Loki 3.0.0, native binary (not the repo's Docker script) | started this run |
| Metrics backend | Prometheus 2.53.0, native | started this run |
| Traces backend | Tempo 2.5.0, native | started this run |
| Push ingestion | Pushgateway 1.9.0, native | started this run |
| Evidence bundle | outputs quoted inline below; the substrate lived under `/tmp/sol-obs-qual/` | |

The repository's `platform/local/scripts/ensure-*.sh` start Loki/Prometheus/
Tempo/Grafana **in Docker**, which is unavailable here. Equivalent native
binaries were started with the repository's own config files
(`platform/local/config/tempo.yaml`, the same OTLP ports). This is a deviation
from the scripted substrate and is stated so the reader can re-run it; it does
not change what the observation is *about* (the framework and CLI against a real
Loki/Prometheus/Tempo).

## 2. Entry point

Procedure: `docs/guides/operations.md` §1–§6, plus `internal/pipeline/audits/AUDIT.md`
§5.3 (observability smoke test). Commands were run from a workspace scaffolded by
the real binary:

```sh
/home/lbendtly/Code/sol/_build/default/cli/bin/main.exe new workspace obsdemo
```

## 3. Step log

### Step 1 — Green path: svc → Kafka → worker, with logs, metrics, traces

- **Command:**

  ```sh
  KAFKA_SECURITY_PROTOCOL=plaintext KAFKA_BROKERS=localhost:9092 \
  SCHEMA_REGISTRY_URL=http://localhost:8081 REDPANDA_ADMIN_URL=http://localhost:9644 \
  LOKI_URL=http://localhost:3100 TEMPO_URL=http://localhost:4318 \
  PUSHGATEWAY_URL=http://localhost:9091 \
  dune exec internal/fixtures/local-demo/bin/demo.exe
  ```

- **Observed (verbatim, assertions block):**

  ```text
  ✓ HTTP: all orders accepted (202)
  ✓ Prometheus: sol_svc_requests_total > 0
  ✓ Prometheus: sol_worker_messages_total > 0
  ✓ Loki: logs received for current order-svc request
  ✓ Tempo: order-svc trace lookup by trace_id
  ✓ Tempo: fulfillment-worker span linked as a child of the same trace
  ```

- **Independently observed in the backends** (not from the demo's assertions):
  - Loki `/loki/api/v1/label/service/values` → `["fulfillment-worker","order-svc","probe"]`.
  - A `sol_svc_requests_total{method="POST",route="/orders",status_class="2xx"} 3`
    series was rendered by the framework; `route` is the declared pattern.
- **Matrix rows:** OB-M1, OB-T1. **Result:** `PASS` (LOCAL).

### Step 2 — Trace/log correlation

- A real `order-svc` line from Loki:

  ```text
  level=info msg="order received" span=receive_order order_id=order-14f507-003 item="Standing Desk Riser" trace_id=6a7e1de7b3715a770a247b38e4e97b20 span_id=eb20b304111f6ef4
  ```

- Tempo's trace for that id:

  ```text
  $ curl -s 'http://localhost:3200/api/traces/6a7e1de7b3715a770a247b38e4e97b20' | jq -r '.batches[].scopeSpans[].spans[].name'
  receive_order
  fulfill_order
  ```

  and the resource `service.name` values were `order-svc` and
  `fulfillment-worker`. The log line's `trace_id` equals the Tempo trace id
  byte-for-byte.
- **Matrix rows:** OB-T1, OB-T2. **Result:** `PASS` (LOCAL).
- **Simultaneously observed:** the trace's resource attributes are `service.name`
  only — no `workspace`/`domain`/`primitive`/`release`/`env`. **OB-T3 `FAIL`.**

### Step 3 — `sol logs` against a real Loki

A line with Sol's identity was pushed directly to Loki, plus a decoy with the
same `service` in another workspace:

```sh
curl -X POST 'http://localhost:3100/loki/api/v1/push' -H 'Content-Type: application/json' \
  -d '{"streams":[{"stream":{"workspace":"obsdemo","domain":"payments","service":"charge-svc","primitive":"svc","release":"r-0123456789abcdef"},"values":[["<ts>","level=info msg=\"crafted marker line\" order_id=obs-probe-1"]]}]}'
curl -X POST 'http://localhost:3100/loki/api/v1/push' -H 'Content-Type: application/json' \
  -d '{"streams":[{"stream":{"workspace":"other-ws","domain":"payments","service":"charge-svc"},"values":[["<ts>","level=info msg=\"SHOULD-NOT-APPEAR other workspace\""]]}]}'
```

```text
$ sol local logs --scope payments/charge_svc --no-follow
Grafana logs: http://localhost:3000/explore?…expr=%22%7Bworkspace%3D%22obsdemo%22%2C%20domain%3D%22payments%22%2C%20service%3D%22charge-svc%22%7D%22…
level=info msg="crafted marker line" order_id=obs-probe-1
```

The `other-ws` line did **not** appear. The selector is exact.
**Matrix row:** OB-L1. **Result:** `PASS` (LOCAL).

### Step 4 — Logs backend loss

Loki was stopped (`kill <loki pid>`), then:

```text
$ sol local status
Observability
  backend  local
  logs     couldn't reach http://localhost:3100/ready: connection failed
  metrics  healthy
...
$ sol local logs --scope payments/charge_svc --no-follow
Grafana logs: http://localhost:3000/explore?…
(couldn't reach http://localhost:3100: connection failed. Falling back to Kubernetes logs for charge_svc...)
Service charge_svc not found in namespace obsdemo-payments.
```

The degradation is visible and names the reason. The `kubectl` fallback could
not deliver pod logs (no cluster). **Matrix rows:** OB-L2, OB-F1.
**Result:** `PASS` (LOCAL) for detection/reporting; `NOT REACHED` (needs a
cluster) for the fallback delivering logs.

**New defect observed at the same boundary.** With the kubeconfig pointing at a
refused endpoint (`0.0.0.0:41467`), an unreachable cluster was reported as a
definite negative:

```text
Service charge_svc not found in namespace obsdemo-payments.
Run 'sol status' to see deployed services.
```

`sol status` correctly reported `UNKNOWN (…connection refused)` for the same
cluster, so the two surfaces disagreed about the same fact.
**Matrix row:** OB-S3. **Result:** `FAIL` → **BUG-121**.

### Step 5 — `sol status`, `sol open`, `sol check`

```text
$ sol check
sol check: ok

$ sol open logs payments/charge_svc --links
http://localhost:3000/explore?orgId=1&left=%7B%22datasource%22:%22loki%22,%22queries%22:%5B%7B%22expr%22:%22%7Bworkspace%3D%22obsdemo%22%2C%20domain%3D%22payments%22%2C%20service%3D%22charge-svc%22%7D%22%7D%5D%7D

$ sol open dashboard --links
http://localhost:3000/d/sol-workspace-overview?var-workspace=obsdemo

$ sol local status
Domains
  comms        UNKNOWN (exited with code 1: … connection refused)
  payments     UNKNOWN (exited with code 1: … connection refused)
Observability
  backend  local
  logs     healthy
  metrics  healthy
```

Every dashboard uid and template variable the links name exists in the
provisioned JSON (`sol-workspace-overview` + `workspace`;
`sol-service-template` + `workspace`/`domain`/`service`; `sol-domain-overview`
+ `workspace`/`domain`). **Matrix rows:** OB-S1, OB-S2, OB-S4, OB-S5, OB-D1.
**Result:** `PASS` (LOCAL / MECHANISM).

**Observation, not a defect.** The Loki probe is `GET /ready` requiring 2xx. A
freshly started Loki 3.x returns `503` on `/ready` until its compactor ring
settles (~10 min) while already serving queries; `sol status` says `HTTP 503`
during that window. That is Loki's own readiness semantics.

### Step 6 — Taxonomy labels on each signal

- App-pushed Loki streams (real demo): labels
  `{"service":"order-svc","service_name":"order-svc"}` — no `workspace`,
  `domain`, `primitive`, `release`, `env`.
- App-pushed metric render: `sol_svc_requests_total{method,route,status_class}`
  — the taxonomy is not on the metric; it is added at scrape time.
- Trace resource attributes: `service.name` only.
- Where the taxonomy *does* come from:
  - Loki: Alloy promotes the list in
    `platform/cloud/modules/platform/main.tf`
    (`observability_taxonomy_labels = ["workspace","domain","service","primitive","release"]`)
    and `cli/lib/local/sol_cli_dev_observability.ml`
    (`["workspace";"domain";"service";"primitive";"release"]`) — **`env` absent**.
  - Metrics: the manifest renders the full taxonomy (including `env`) as pod
    labels, and the pinned `prometheus-community/prometheus` chart's
    `kubernetes-pods` job applies `labelmap __meta_kubernetes_pod_label_(.+)`,
    so all six reach the series.

**Matrix rows:** OB-L3 (`FAIL` → **OBS-049**), OB-M2 (`PASS`, MECHANISM),
OB-T3 (`FAIL` → **OBS-050**).

## 4. Row roll-up

| Row | Evidence class required | Result | Where the evidence is |
|---|---|---|---|
| OB-L1 logs selectable by identity, exact | LOCAL | PASS | step 3 |
| OB-L2 backend loss degrades, names reason | LOCAL | PASS | step 4 |
| OB-L3 `env` on log identity | MECHANISM+LOCAL | FAIL | step 6 |
| OB-L4 unparseable stream | MECHANISM | NOT REACHED | not induced |
| OB-M1 svc/worker metrics | LOCAL | PASS | step 1 |
| OB-M2 metric taxonomy | MECHANISM | PASS | step 6 |
| OB-M3 caught by provider system | LIVE | NOT REACHED | no cloud target |
| OB-T1 trace across service+worker | LOCAL | PASS | step 2 |
| OB-T2 `trace_id` ↔ trace | LOCAL | PASS | step 2 |
| OB-T3 trace taxonomy | LOCAL | FAIL | step 2/6 |
| OB-T4 `sol open traces` | MODELED | NOT REACHED | OBS-045 |
| OB-D1 dashboard definitions/links | MECHANISM | PASS | step 5 |
| OB-D2 panel truth | LIVE | NOT REACHED | no Grafana/cluster |
| OB-S1 workload health | LOCAL+LIVE | PASS (UNKNOWN case) | step 5 |
| OB-S2 backend reachability | LOCAL | PASS | step 4/5 |
| OB-S3 unreachable ≠ not-deployed | LOCAL | FAIL | step 4 |
| OB-S4 `sol open` resolution | LOCAL | PASS | step 5 |
| OB-S5 `sol check` | LOCAL | PASS | step 5 |
| OB-S6 incident path stays in Sol | LIVE | NOT REACHED | no cluster/target |
| OB-F1 telemetry loss visible | LOCAL | PASS | step 4 |
| OB-F2 decode error → DLQ | LOCAL | NOT REACHED | not induced |
| OB-F3 Kafka lag/broker loss | LIVE | NOT REACHED | no scrape |
| OB-F4 deploy failure visible | LIVE | NOT REACHED | no cluster/target |
| OB-R1 local makes no promise | MODELED | PASS | — |
| OB-R2 self_hosted_durable | LIVE | BLOCKED | AWS-only, no cloud |
| OB-R3 external ship | LIVE | NOT REACHED | no endpoint |
| OB-O1 deploy→…→recovery | LIVE | NOT REACHED | no cluster/target |

## 5. What this run does not establish

- **Anything about Kubernetes or a deployed target.** No cluster exists on this
  host. Workload health, `kubectl` log fallback, the deployed-backend URL
  resolution, Grafana rendering, Alertmanager delivery and the rollback loop are
  `NOT REACHED`.
- **Alert firing or delivery.** No Alertmanager was run; only the rule text in
  the platform module was read.
- **The decode-error path.** `SolWorkerDecodeDrops`, its structured log line,
  DLQ diversion and offset ordering were not induced. This is the cheapest next
  row and the highest-value one.
- **`self_hosted_durable` and `external`.** Cloud/endpoint-gated.
- **Nothing here is `LIVE`.** A framework run on one host is not evidence about
  a production profile.

## 6. Findings and ledger updates implied

| Finding | Class | State before | State after |
|---|---|---|---|
| `env` not promoted to Loki stream labels | MECHANISM+LOCAL | not recorded | `OBS-049` filed (`READY_FOR_ENGINEERING`) |
| Unreachable cluster reported as "not deployed" | LOCAL | FND-0024 residual, unrecorded | `BUG-121` filed (`READY_FOR_ENGINEERING`) |
| Traces carry no Sol taxonomy identity | LOCAL | not recorded | `OBS-050` filed (`BACKLOG`, decision required) |

`QUALIFICATION_STATUS.md` gains an observability section pointing here; no
provider invariant moves.
