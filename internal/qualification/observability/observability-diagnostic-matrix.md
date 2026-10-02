# Observability & diagnostic qualification matrix

The executable contract for the observability workstream
(`README.md`). Each row is one claim Sol makes about observability or
diagnosis, the evidence class the claim needs, and where it stands on
**2026-10-02** (`main @ 2a2c5a7c`). Verdicts are `QUALIFIED`, `UNQUALIFIED`,
`DEFECT` (established wrong), or `BLOCKED` (an external input is required).

Evidence classes: `MODELED` / `MECHANISM` / `LOCAL` / `LIVE` — see `README.md`.
**No `LIVE` row is claimed**: this host has no Kubernetes (Docker unavailable),
so nothing was observed on a deployed cluster or a cloud target. Rows that
require that are `UNQUALIFIED (live)` or `BLOCKED`, never weakened.

The run that produced the LOCAL evidence is
[`../records/2026-10-02-observability-local-qualification.md`](../records/2026-10-02-observability-local-qualification.md).

---

## A. Logs

### OB-L1 — A unit's logs are queryable by Sol's identity, and only that unit's

- **Claim:** `sol logs --scope domain/unit --no-follow` queries the workspace
  logs backend with `{workspace, domain, service}` and returns exactly that
  unit's lines (`docs/guides/operations.md` §3; `docs/architecture/observability-design.md`).
- **Evidence:** LOCAL — a real Loki, a real scaffolded workspace, the real
  binary. Verbatim command and output in the run record (§3).
- **Verdict:** `QUALIFIED (LOCAL)`.
- **Failure walk:**
  - *Symptom:* a line from a same-named unit in another workspace appears in
    this unit's logs (or this unit's line is missing).
  - *Detection:* the operator sees a foreign line, or an expected line is absent.
  - *Investigation:* `sol logs --scope … --no-follow`; the selector is printed
    in the Grafana URL header line.
  - *Cause:* not applicable — the selector is exact.
  - *Recovery:* not applicable.
- **Observed:** `{workspace="obsdemo", domain="payments", service="charge-svc"}`
  returned the `obsdemo` line and **excluded** the identical-service line pushed
  under `workspace="other-ws"`.

### OB-L2 — A missing or unreachable logs backend degrades instead of failing

- **Claim:** `sol logs` is Loki-first and falls back to `kubectl logs`, naming the
  reason; `sol status` reports the backend's reachability (`operations.md` §2–§3).
- **Evidence:** LOCAL, partial — the degradation messages were observed; the
  `kubectl` fallback itself could not be exercised (no cluster).
- **Verdict:** `QUALIFIED (LOCAL)` for the detection/reporting half;
  `UNQUALIFIED (live)` for the fallback delivering real pod logs.
- **Failure walk:**
  - *Symptom:* `sol logs` prints nothing, or an old snapshot.
  - *Detection:* `sol status` prints
    `logs  couldn't reach http://localhost:3100/ready: connection failed`.
  - *Investigation:* the `sol logs` header line names the backend and the query.
  - *Cause:* the unreachable URL is named.
  - *Recovery:* restart the backend; the same query then returns lines.
- **Observed:** with Loki stopped, `sol local status` degraded the `logs` line
  and `sol local logs --no-follow` printed
  `(couldn't reach http://localhost:3100: connection failed. Falling back to Kubernetes logs for charge_svc...)`.

### OB-L3 — The log identity `env` is present

- **Claim:** every log line carries `workspace`, `env`, `domain`, `service`,
  `primitive`, `release`; "all six labels, including `env`, are emitted"
  (`docs/architecture/observability-design.md` §Identity; OBS-008).
- **Evidence:** MECHANISM + LOCAL — the manifest renders `env` as a pod label
  (`cli/lib/workspace/sol_cli_manifest_yaml.ml`); the Alloy promotion list omits
  it (`platform/cloud/modules/platform/main.tf` and
  `cli/lib/local/sol_cli_dev_observability.ml`); the local run's Loki streams
  show the app-pushed labels, and the deployed path's promotion list was read
  from the artifact that owns it.
- **Verdict:** `DEFECT` — `env` reaches metric labels (the Prometheus chart's pod
  label map) but **never** a Loki stream label. Filed as **OBS-049**.
- **Failure walk:**
  - *Symptom:* a LogQL query filtering on `env` (e.g. a prod-only log view)
    returns nothing while the same series exists in Prometheus.
  - *Detection:* the label is absent from `/loki/api/v1/labels`.
  - *Investigation:* compare the Loki label set with the pod labels.
  - *Cause:* the Alloy/Derived-promotion list has five labels, not six.
  - *Recovery:* add `env` to both promotion lists (OBS-049).

### OB-L4 — An unparseable backend response does not silently disappear

- **Claim (implicit):** `sol logs` is complete for the lines the backend holds.
  **Finding on record:** FND-0027 — Loki stream parse failures are dropped
  without a trace.
- **Evidence:** MECHANISM (code read); not induced on a real Loki (the API
  always returns `[ts, line]` pairs, so the failure is hard to produce honestly).
- **Verdict:** `UNQUALIFIED` (inherits FND-0027; no ticket in the tree).

## B. Metrics

### OB-M1 — `-svc` and `-worker` expose the metrics the alerts and dashboards read

- **Claim:** `sol_svc_requests_total`/`sol_svc_request_duration_seconds` and
  `sol_worker_messages_total`/`sol_worker_message_duration_seconds` are emitted
  with the declared route pattern and bounded labels (`AUDIT.md` §4; `sol-worker.md`).
- **Evidence:** LOCAL — a real demo run rendered the metrics with
  `route="/orders"` (the declared pattern, not the raw path) and
  `status_class="2xx"`, and the worker counters increased with `status="ok"`.
- **Verdict:** `QUALIFIED (LOCAL)`.
- **Failure walk:**
  - *Symptom:* a dashboard's request-rate panel is empty, or a route label
    explodes in cardinality.
  - *Detection:* `sol_status`'s `metrics` line / a Prometheus query.
  - *Investigation:* `sol open metrics <scope>`; the route label is the pattern.
  - *Cause:* a missing scrape annotation or a wrong port.
  - *Recovery:* the manifest's `prometheus.io/scrape`/`prometheus.io/port`
    (present for both primitives).

### OB-M2 — Metric labels carry the Sol taxonomy so alerts can name the unit

- **Claim:** alert rules group by `workspace, env, domain, service`
  (`platform/cloud/modules/platform/main.tf`); the identity table says metrics
  carry the taxonomy.
- **Evidence:** MECHANISM — the rendered pod labels carry the taxonomy
  (including `env`), the manifests annotate pods for scraping, and the pinned
  `prometheus-community/prometheus` chart's `kubernetes-pods` job applies
  `labelmap __meta_kubernetes_pod_label_(.+)`.
- **Verdict:** `QUALIFIED (MECHANISM)`; `UNQUALIFIED (live)` until a cluster is
  scraped and the labels are observed on a real series.
- **Note:** `-fn` uses Pushgateway, a different ingestion path; the push path
  must set the same labels or the same alerts cannot name the function.

### OB-M3 — A metric whose truth lives in another system is not duplicated

- **Claim:** cloud-provider and managed-resource facts are read from their own
  system (CloudWatch) and surfaced, never mirrored (`observability-design.md`
  §Who is authoritative).
- **Evidence:** MODELED.
- **Verdict:** `UNQUALIFIED (live)` — needs a cloud target.

## C. Traces and correlation

### OB-T1 — A request's trace spans the HTTP service, Kafka, and the worker

- **Claim:** W3C `traceparent` is propagated through Kafka; the consumer joins
  the producer's trace with no manual threading (`AUDIT.md` §4; OBS-042).
- **Evidence:** LOCAL — independently verified in Tempo, not via the demo's own
  assertion: trace `6a7e1de7…` contains `order-svc`'s `receive_order` and
  `fulfillment-worker`'s `fulfill_order` as one trace.
- **Verdict:** `QUALIFIED (LOCAL)`.

### OB-T2 — A log line's `trace_id` points at its trace

- **Claim:** a `trace_id` in a Loki line is the Tempo trace id; the datasource's
  `derivedFields` makes it clickable (`observability-backends.md` §Tracing).
- **Evidence:** LOCAL — the `trace_id` field of the `order-svc` log line equals
  the Tempo trace id for the same request, byte-for-byte (run record §4).
- **Verdict:** `QUALIFIED (LOCAL)` for the id/encoding; the Grafana click-through
  is `UNQUALIFIED` (no Grafana).
- **Also:** the deploy-event marker's join key is `deployment_id`, emitted only
  after the record is persisted (`observability-design.md`) — `UNQUALIFIED (live)`.

### OB-T3 — A trace carries the Sol taxonomy identity

- **Claim:** "every … trace … must carry the same ownership identity:
  `workspace`, `env`, `domain`, `service`, `primitive`, `release`"
  (`observability-design.md` §Identity).
- **Evidence:** LOCAL — the Tempo trace's resource attributes are `service.name`
  only; the app-pushed Loki stream carries `service` plus whatever `~context`
  the scaffold passes (`[("team","payments")]`), and `Obs_tempo` is created
  without any taxonomy context.
- **Verdict:** `DEFECT` — traces cannot be correlated to the taxonomy the way
  logs and metrics can. Filed as **OBS-050**.
- **Failure walk:**
  - *Symptom:* a slow span cannot be attributed to a workload/domain/release
    except through `service.name`.
  - *Detection:* inspect the trace's resource attributes.
  - *Investigation:* none available — there is no `sol open traces` (OBS-045).
  - *Cause:* the framework never sets the taxonomy on span resources.
  - *Recovery:* OBS-050.

### OB-T4 — There is a CLI surface for traces

- **Claim:** none — the design doc says traces have no CLI surface yet; OBS-045
  owns `sol open traces`.
- **Evidence:** MODELED (the command is absent from `sol open`).
- **Verdict:** `UNQUALIFIED` (documented gap, ticket OBS-045 in `BACKLOG`).

## D. Dashboards

### OB-D1 — The provisioned dashboards exist, and `sol open` links resolve to them

- **Claim:** four/five dashboards are provisioned and `sol open <view> <scope>`
  builds a URL that selects the same labels (`observability-design.md`,
  `observability-backends.md` §Dashboards).
- **Evidence:** MECHANISM — every JSON parses; uids match `Sol_cli_open`
  (`sol-workspace-overview`, `sol-service-template`, `sol-domain-overview`,
  `sol-release-timeline`, `sol-target-infrastructure`); the template variables
  a link sets (`var-workspace`, `var-domain`, `var-service`) exist on the
  dashboards; the Loki/Prometheus datasource uids (`loki`, `prometheus`) match
  the provisioned ConfigMaps.
- **Verdict:** `QUALIFIED (MECHANISM)`; `UNQUALIFIED (live)` — the panels were
  not rendered against a live Grafana (the doc's own "Known gaps" say so).
- **Observed:** `sol open dashboard --links` →
  `http://localhost:3000/d/sol-workspace-overview?var-workspace=obsdemo`;
  `sol open logs payments/charge_svc --links` → a Loki Explore URL whose
  `expr` is `{workspace="obsdemo", domain="payments", service="charge-svc"}`.

### OB-D2 — A dashboard panel shows a queryable fact, not a fabricated one

- **Claim:** no second system of record; every panel reads the source that owns
  the fact (`observability-design.md` §Who is authoritative; `sol open infra`).
- **Evidence:** MODELED.
- **Verdict:** `UNQUALIFIED (live)` — needs a cluster with the observability
  stack to move a panel.

## E. Sol diagnostic surfaces

### OB-S1 — `sol status` reports workload health derived from the cluster

- **Claim:** health comes from Kubernetes' own diagnosis, and an unhealthy scope
  names the cause (`operations.md` §2).
- **Evidence:** LOCAL-adjacent — with **no cluster**, `sol status` correctly
  reported `UNKNOWN (<reason>)` rather than "healthy" or "not deployed". The
  positive/negative health derivation needs a cluster.
- **Verdict:** `QUALIFIED (LOCAL)` for "an unanswerable read is UNKNOWN";
  `UNQUALIFIED (live)` for the diagnosis itself.

### OB-S2 — `sol status` reports the observability backend's reachability

- **Claim:** the `Observability` block reports reachability from where the
  command runs, and never guesses a URL it cannot see (`operations.md` §2).
- **Evidence:** LOCAL — healthy with Loki/Prometheus up; the exact unreachable
  reason printed with Loki down; for a deployed backend it prints the
  port-forward command instead of guessing.
- **Verdict:** `QUALIFIED (LOCAL)` for the local backend;
  `UNQUALIFIED (live)` for the deployed-backend resolution.
- **Note:** the Loki probe is `/ready` and requires a 2xx. A freshly started
  Loki 3.x returns `503` on `/ready` until its compactor ring settles (~10 min)
  while already serving queries; `sol status` therefore says `HTTP 503` during
  that window. That is Loki's own readiness signal, not a Sol defect, but it is
  worth recording as an operator expectation.

### OB-S3 — An unreachable cluster is never reported as "not deployed"

- **Claim:** the distinct third state INFRA-063 introduced — `sol logs` and
  `sol fn run` say *could not check* when the cluster is unreachable, and
  *not deployed* only when a real answer said so.
- **Evidence:** LOCAL — **observed the opposite**: with the kubeconfig pointing
  at a refused endpoint, `sol logs` printed
  `Service charge_svc not found in namespace obsdemo-payments.` The classifier
  (`presence_of_probe_result`) maps *any* non-zero `kubectl` exit to `Absent`;
  INFRA-063 fixed only the "kubectl could not be run" case
  (`Error`), not "kubectl ran and could not reach the cluster".
- **Verdict:** `DEFECT` — residual of FND-0024. Filed as **BUG-121**.

### OB-S4 — `sol open` opens or prints the right surface per scope

- **Claim:** `sol open <view> [SCOPE]` / `sol open infra --target` resolution;
  `--links` prints URLs; it exits with the reason when it cannot resolve one
  (`operations.md` §6).
- **Evidence:** LOCAL — workspace/domain/unit link building observed with the
  real binary; the `--links` output is data.
- **Verdict:** `QUALIFIED (LOCAL)` for resolution; `UNQUALIFIED (live)` for the
  deployed-backend base-domain path.

### OB-S5 — `sol check` validates declarations without a cluster

- **Claim:** `sol check` validates the workspace without Docker or Kubernetes
  and has the documented exit vocabulary (`operations.md` §5).
- **Evidence:** LOCAL — `sol check: ok` in a freshly scaffolded workspace.
- **Verdict:** `QUALIFIED (LOCAL)` for the valid case; the failing (`exit 2`)
  and could-not-run (`exit 1`) cases are not exercised here.

### OB-S6 — The documented day-two path stays inside Sol

- **Claim:** the incident path from alert/log/metric to status, logs, rollback
  and migration uses Sol first (`AUDIT.md` §4).
- **Evidence:** MODELED. Several steps are cluster/cloud-gated and unrun.
- **Verdict:** `UNQUALIFIED (live)`.

## F. Failure visibility

### OB-F1 — A lost telemetry backend is a visible degradation, not a silent one

- **Claim:** telemetry loss is a degraded mode with an alert
  (`SolTelemetryTargetDown`) and is not confused with a data-durability event
  (`alert-runbooks.md` §Telemetry).
- **Evidence:** LOCAL for the *visibility* (the `sol status` degradation line);
  MECHANISM for the rule (the expr exists in the platform module).
- **Verdict:** `QUALIFIED (LOCAL)` for the surface; the alert firing/delivery is
  `BLOCKED` (no Alertmanager, no receiver).

### OB-F2 — A message a worker cannot decode is visible, diverted, and recoverable

- **Claim:** `SolWorkerDecodeDrops` fires on
  `increase(sol_worker_decode_errors_total[5m])`; a structured log line names the
  error and topic; the record is parked on `<topic>.<group>.dlq` (or legitimately
  acked-and-dropped), and its source offset advances only after the DLQ publish
  (`alert-runbooks.md` §Message drop; OBS-047).
- **Evidence:** MODELED/MECHANISM — the counter and its help text were observed
  at `0` in the green path; the failure itself was **not** induced.
- **Verdict:** `UNQUALIFIED` — the next run must inject an undecodable record and
  observe the counter, the log line, the DLQ topic, and the offset ordering.
  This is the highest-value open row in the workstream.

### OB-F3 — Kafka lag and broker loss are detectable

- **Claim:** `SolKafkaConsumerLagHigh`/`SolKafkaBrokerDown` fire on Redpanda's
  own metrics.
- **Evidence:** MECHANISM + a documented gap: the platform does not scrape
  Redpanda by default, so the rules are silent until the target exposes the
  scrape (`observability-backends.md` §Alerting). The live group state was
  reachable (`rpk group describe`), but no Sol surface consumed it.
- **Verdict:** `UNQUALIFIED (live)`; the silence is documented, not a defect.

### OB-F4 — A deploy failure is visible as "the current release is bad"

- **Claim:** `SolRolloutFailed` catches a rollout that never becomes available;
  `sol deployments`/`sol logs` are the detail view (`observability-backends.md`).
- **Evidence:** MODELED.
- **Verdict:** `UNQUALIFIED (live)` — needs a cluster and a target.

## G. Retention and durability

### OB-R1 — The `local` backend makes no durability promise

- **Claim:** `local` is "dev and throwaway clusters. No durability promise."
- **Evidence:** MODELED (the backend mode table; the in-cluster Loki/Prometheus
  storage is the chart's).
- **Verdict:** `QUALIFIED (MODELED)` — the absence of a promise is the contract;
  nothing is claimed to preserve.

### OB-R2 — `self_hosted_durable` keeps logs and metrics across teardown

- **Claim:** Loki chunks/index in S3 and Thanos object storage, with
  `prevent_destroy` on the buckets (`observability-backends.md`).
- **Evidence:** MODELED/STATIC (Terraform). The doc itself records the gap: "the
  full S3-backed path has not been exercised against a live cluster."
- **Verdict:** `BLOCKED` — AWS-only (IRSA), cloud-gated; cannot be qualified on
  this host.

### OB-R3 — `external` ships logs/metrics to a configured endpoint

- **Claim:** Alloy ships logs to the external endpoint and Prometheus
  `remote_write`s metrics; `sol logs` reads with `--loki-base-url` and credentials.
- **Evidence:** MECHANISM for the read side (the flag/credential path exists and
  the local Loki read is qualified); the ship side is MODELED.
- **Verdict:** `UNQUALIFIED (live)` — needs an external endpoint.

## H. Operator workflows (deploy → failure → diagnose → rollback → recovery)

### OB-O1 — The full recovery loop

- **Claim:** `operations.md` §1/§4/§7 — deploy, observe a failure, roll back to a
  known-good release, and recover.
- **Evidence:** none available on this host.
- **Verdict:** `UNQUALIFIED (live)` — needs a cluster, a target, and (for cloud)
  credentials. The rollback qualification already on record
  (`2026-10-02_rollback_fidelity_qualification.md`) is the closest evidence and
  is not inherited by this workstream.

---

## Findings filed

| Id | Row | Severity | Evidence | Ticket |
|---|---|---|---|---|
| `env` is not a Loki stream label | OB-L3 | low | MECHANISM + LOCAL | `OBS-049` |
| An unreachable cluster is reported as "not deployed" | OB-S3 | medium | LOCAL | `BUG-121` |
| Traces carry no Sol taxonomy identity | OB-T3 | medium | LOCAL | `OBS-050` |

## What would move the most rows

1. A Kubernetes cluster on this host (the repository's Docker-based
   `sol local infra up`) — it would make OB-S1/S2/S4, OB-D1/D2, OB-F4 and the
   `kubectl` fallback of OB-L2 observable.
2. An Alertmanager with a real receiver — OB-F1's firing/delivery and the
   alert-routing contract.
3. A cloud target — OB-M3, OB-R2, OB-O1.
4. The decode-error injection — OB-F2, which needs only a broker and a crafted
   record and is the cheapest next row to close.
