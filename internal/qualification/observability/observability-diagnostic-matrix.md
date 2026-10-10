# Observability & diagnostic qualification matrix

The executable contract for the observability workstream
(`README.md`). Each row is one claim Sol makes about observability or
diagnosis, the evidence class the claim needs, and where it stands on
**2026-10-02** (`main @ 2a2c5a7c`, updated after runs 2–5). Verdicts are
`QUALIFIED`, `UNQUALIFIED`, `DEFECT` (established wrong), or `BLOCKED` (an
external input is required).

Evidence classes: `MODELED` / `MECHANISM` / `LOCAL` / `LIVE` — see `README.md`.
**No `LIVE` row is claimed**: this host has no Kubernetes (Docker unavailable),
so nothing was observed on a deployed cluster or a cloud target. Rows that
require that are `UNQUALIFIED (live)` or `BLOCKED`, never weakened.

The runs that produced the LOCAL evidence are
[`../records/2026-10-02-observability-local-qualification.md`](../records/2026-10-02-observability-local-qualification.md)
(run 1),
[`../records/2026-10-02-observability-run2-local.md`](../records/2026-10-02-observability-run2-local.md)
(run 2),
[`../records/2026-10-02-observability-run3-alert-route.md`](../records/2026-10-02-observability-run3-alert-route.md)
(run 3),
[`../records/2026-10-02-observability-run4-local.md`](../records/2026-10-02-observability-run4-local.md)
(run 4, `OBS-050`/`BUG-122` re-qualification and the `sol check` exit cases), and
[`../records/2026-10-02-observability-run5-traces.md`](../records/2026-10-02-observability-run5-traces.md)
(run 5, `OBS-045`'s traces view).

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
  under `workspace="other-ws"`. Run 4 re-verified it on an app-pushed stream:
  after `OBS-050` the demo's own `order-svc` stream carries
  `{workspace,env,domain,service,primitive,release}` and is selected by the same
  `{workspace,domain,service}` query (run-4 record §2.4).

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
  label map) but **never** a Loki stream label. Filed as **OBS-049**, and
  **resolved 2026-10-02** by #926: both promotion lists carry `env` now, and
  `check_platform_component_drift.py` requires the two to match and to be the
  documented six. The discovery evidence above is unchanged — it is what the run
  saw.
- **Failure walk:**
  - *Symptom:* a LogQL query filtering on `env` (e.g. a prod-only log view)
    returns nothing while the same series exists in Prometheus.
  - *Detection:* the label is absent from `/loki/api/v1/labels`.
  - *Investigation:* compare the Loki label set with the pod labels.
  - *Cause:* the Alloy/Derived-promotion list has five labels, not six.
  - *Recovery:* add `env` to both promotion lists (OBS-049).

### OB-L4 — An unparseable backend response is rejected, not silently dropped

- **Claim (implicit):** `sol logs` is complete for the lines the backend holds.
  `FND-0027` recorded an older parser that filtered malformed values and returned
  `Ok`, silently truncating.
- **Evidence:** LOCAL — run 2 pointed `sol logs` at a stub returning three
  malformed shapes (a non-pair value; a stream with no `values`; a good stream
  beside a malformed one). Every case was rejected with the reason and degraded
  explicitly; no partial result was returned. See the run-2 record §3.
- **Verdict:** `QUALIFIED (LOCAL)`; **FND-0027 is `SUPERSEDED`** by the parser
  rewrite. One new low observation: the message says "couldn't reach" for a
  response that was reached (a parse error reported as a transport failure).
  Filed as **BUG-123**.

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

### OB-T3 — A trace carries the Sol taxonomy identity

- **Claim:** "every … trace … must carry the same ownership identity:
  `workspace`, `env`, `domain`, `service`, `primitive`, `release`"
  (`observability-design.md` §Identity).
- **Evidence:** run 1 found the Tempo trace's resource attributes were
  `service.name` only and filed `OBS-050` (`DEC-064`). Run 4 re-observed it after
  `OBS-050`: a real demo trace
  (`465dc75872a39152fec689f8d91d88b6`) carries all six as resource attributes,
  the trace is selectable by each, and the app-pushed Loki stream carries the
  same values (run-4 record §2).
- **Verdict:** `QUALIFIED (LOCAL)`. History: `DEFECT` → `OBS-050` → qualified.
- **Failure walk:**
  - *Symptom:* a slow span cannot be attributed to a workload/domain/release
    except through `service.name`.
  - *Detection:* inspect the trace's resource attributes.
  - *Investigation:* query Tempo by `resource.<label>`; each returns the trace
    (`{resource.workspace="obsdemo"}` → 6 traces, negative control → 0).
  - *Cause:* the framework never sets the taxonomy on span resources (before
    `OBS-050`).
  - *Recovery:* `OBS-050` (PR #961); `sol open traces` is still OBS-045.

### OB-T4 — There is a CLI surface for traces

- **Claim:** `sol open traces [SCOPE]` opens (or, with `--links`, prints) a Grafana
  Explore view whose Tempo query selects the scope over the identity Sol emits.
- **Evidence:** LOCAL — run 5. `sol open traces` builds a TraceQL query over
  `resource.workspace`/`resource.domain`/`resource.service` (the attributes
  `OBS-050` puts on every span). Each pane decodes to valid JSON naming the
  `tempo` datasource with `queryType: traceql`, and executing each query through
  Grafana's Tempo datasource proxy returned the right traces: workspace 6,
  domain 3, unit `order-svc` 3, unit `fulfillment-worker` **the same 3** (a
  cross-unit trace appears under both), a foreign unit 0. `self_hosted_durable`
  and `external` resolve or explain, never a broken link; `resource/<type>` has
  no traces view and says so. Run 5 also found and fixed an invalid-JSON pane in
  the shared Grafana URL builder, which affected the shipped `sol open logs`.
- **Verdict:** `QUALIFIED (LOCAL)`. History: `UNQUALIFIED` (documented gap) →
  `OBS-045` → qualified.
- **Failure walk:**
  - *Symptom:* a trace cannot be reached from the CLI, or the URL opens an empty
    Explore pane.
  - *Detection:* `sol open traces <scope> --links`; the pane's query.
  - *Investigation:* decode the `left=` pane and run its query against Tempo.
  - *Cause:* the view was absent; the pane builder also single-encoded the query's
    quotes, so the JSON was invalid.
  - *Recovery:* `OBS-045`; the deployed two-`SOL_DOMAIN` trace remains `LIVE`.

## D. Dashboards

### OB-D1 — The provisioned dashboards exist, and `sol open` links resolve to them

- **Claim:** four/five dashboards are provisioned and `sol open <view> <scope>`
  builds a URL that selects the same labels (`observability-design.md`,
  `observability-backends.md` §Dashboards).
- **Evidence:** MECHANISM + LOCAL — run 2 ran a native Grafana 11.3.0 with the
  repo's dashboards and datasource definitions file-provisioned. Grafana loaded
  all six dashboards (their uids match `Sol_cli_open`, and the template variables
  a link sets exist), provisioned the Loki/Tempo/Prometheus datasources, and
  served queries through its proxy: Loki label values, a Prometheus `up` query,
  and a Tempo trace search each returned real data. See the run-2 record §4.
- **Verdict:** `QUALIFIED (LOCAL)` for the definitions, the datasource wiring,
  and query execution; panel *data* under the taxonomy labels is `NOT REACHED`
  without a cluster whose scrape promotes the pod labels (the local static scrape
  does not). Run 4 re-verified the proxy path and served a Loki label value
  (`workspace=["obsdemo"]`) and a Tempo search from the taxonomy-labelled data.
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
- **Verdict:** `DEFECT` — residual of FND-0024. Filed as **BUG-121**, and
  **resolved 2026-10-02** by #925: the probe uses `--ignore-not-found`, an empty
  successful read is `Absent`, and every other failure is `Uncheckable` naming
  the reason. Re-verified with the real binary against a refused kubeconfig,
  which now prints `could not check … (the cluster could not be reached)`.

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
- **Evidence:** run 1 saw `sol check: ok` in a freshly scaffolded workspace. Run
  4 induced the other two cases on a scaffolded workspace: a removed Dockerfile
  (a check that ran) exited **1**, not the documented 2; an unreadable `sol.yml`
  raised an uncaught `Sys_error` and exited 125, not the documented 1 with a
  diagnostic. `--scope nope` correctly exited 2 (run-4 record §4).
- **Verdict:** `QUALIFIED (LOCAL)` for the valid case and for the scope-miss
  case; `DEFECT` for the failing and could-not-run cases. Filed as **BUG-124**;
  the fix is on `BUG-124/sol-check-exit-vocabulary`.

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
  MECHANISM for the rule (the expr exists in the platform module); LOCAL for the
  *delivery mechanism* — run 3 started a native Alertmanager 0.27.0 with a webhook
  receiver, ran `sol alert test` (contract preflight, `--dry-run` body, live POST),
  and observed the alert become `active` and Alertmanager deliver a firing
  notification to the receiver. See the run-3 record.
- **Verdict:** `QUALIFIED (LOCAL)` for the surface and for the alert delivery
  mechanism (contract → acceptance → routing → receiver). The specific
  `SolTelemetryTargetDown` *firing* still needs a cluster whose `monitoring`
  scrape can go down, and the delivered-and-acknowledged-by-the-owner result is
  HARDEN-002's operator-gated evidence.

### OB-F2 — A message a worker cannot decode is visible, diverted, and recoverable

- **Claim:** `SolWorkerDecodeDrops` fires on
  `increase(sol_worker_decode_errors_total[5m])`; a structured log line names the
  error and topic; the record is parked on `<topic>.<group>.dlq` (or legitimately
  acked-and-dropped), and its source offset advances only after the DLQ publish
  (`alert-runbooks.md` §Message drop; OBS-047).
- **Evidence:** LOCAL — run 2 induced an undecodable record at the real broker
  against the venus `notify_worker` and read the result back independently:
  the structured Loki line (error, raw length, topic, trace id), the
  `sol_worker_decode_errors_total` counter (`1`, then `2`, and no
  `sol_worker_messages_total` sample), the DLQ record (raw value + key preserved,
  `X-Sol-Decode-Error` and `X-Sol-Origin-Group` present), and the source offset
  advancing (`15 → 16`). See the run-2 record §2.
- **Verdict:** `QUALIFIED (LOCAL)` for the default `Route_to_dlq` path. The
  `Ack_and_drop` alternative is covered by the repository's Kafka integration
  suite, not re-run here. The DLQ-**publish-failure** branch (publish fails ⇒ no
  ack) is code-verified only — `NOT REACHED`.

### OB-F3 — Kafka lag and broker loss are detectable

- **Claim:** `SolKafkaConsumerLagHigh`/`SolKafkaBrokerDown` fire on Redpanda's
  own metrics.
- **Evidence:** run 2 found the lag rule used `redpanda_kafka_consumer_group_lag`,
  which Redpanda v26.2.2 does not expose (0 series on both `/public_metrics` and
  the scraped series), and filed `BUG-122`. `BUG-122` (#944) replaced it with a
  derivation over `redpanda_kafka_consumer_group_committed_offset` and
  `redpanda_kafka_max_offset` and fixed the annotation labels. Run 4 evaluated
  the corrected expression against the live broker: it returns a lag per
  group/topic (`5` for `comms-notify-worker` on `venus-payments-charges`) equal
  to the broker's own `rpk group describe` `LAG 5`, while the old metric still
  returns 0 series (run-4 record §3). `SolKafkaBrokerDown`'s
  `up{job=~".*redpanda.*"}` is sound once a scrape exists; the platform
  deliberately configures none, which `observability-backends.md` documents.
- **Verdict:** `QUALIFIED (LOCAL)` for the lag half after `BUG-122`; the
  broker-down half is `QUALIFIED (LOCAL)` conditional on a Redpanda scrape.

### OB-F4 — A deploy failure is visible as "the current release is bad"

- **Claim:** `SolRolloutFailed` catches a rollout that never becomes available;
  Kubernetes plus the configured telemetry backend are the detail view
  (`observability-backends.md`).
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

| Finding | Row | Severity | Evidence | Ticket | Status |
|---|---|---|---|---|---|
| `env` is not a Loki stream label | OB-L3 | low | MECHANISM + LOCAL | `OBS-049` | fixed, `DONE` (#926) |
| An unreachable cluster is reported as "not deployed" | OB-S3 | medium | LOCAL | `BUG-121` | fixed, `DONE` (#925) |
| `SolKafkaConsumerLagHigh` uses a metric Redpanda does not expose, and annotation labels that do not exist | OB-F3 | medium | LOCAL | `BUG-122` | fixed, `DONE` (#944); re-verified run 4 |
| Traces carry no Sol taxonomy identity | OB-T3 | medium | LOCAL | `OBS-050` | fixed (PR #961); re-verified `QUALIFIED (LOCAL)` in run 4 |
| `sol check` returns 1 for a failed check and crashes on an unreadable `sol.yml` | OB-S5 | medium | LOCAL | `BUG-124` | fixed, `DONE` (#971) |
| The Grafana Explore `left` pane is invalid JSON after one URL-decode (quotes single-encoded), so `sol open logs` and the new traces view open a broken pane | OB-L1/OB-T4 | medium | LOCAL | — (found by `OBS-045`) | fixed in `OBS-045`; URL-pane round-trip test added |
| FND-0027 malformed-response silent drop | OB-L4 | — | LOCAL | — | `SUPERSEDED` (parser rewritten; fails closed) |

## What would move the most rows

1. A Kubernetes cluster on this host (the repository's Docker-based
   `sol local deploy`) — it would make OB-S1/S2/S4, OB-D1/D2, OB-F4 and the
   `kubectl` fallback of OB-L2 observable, and it is what makes the `SOL_*`
   identity a manifest-injected pod fact rather than a manually-set process
   environment (OB-T3's deployed half, and the two-domain crossing trace for
   OB-T4).
2. A cluster whose `monitoring` scrape can go down — OB-F1's specific
   `SolTelemetryTargetDown` firing (the delivery route itself was qualified in
   run 3 with a local Alertmanager).
3. A cloud target — OB-M3, OB-R2, OB-O1.
4. Any remaining LOCAL row. Runs 2–5 closed OB-F2 (decode/DLQ), OB-L4/FND-0027,
   OB-D1, OB-F3 (defect fixed), OB-T3, OB-T4, and the alert delivery route, and
   filed BUG-124 from the `sol check` exit cases. The executable-without-a-cluster
   surface is exhausted; what is left needs a Kubernetes cluster, a cloud
   account, or the operator's acknowledgement.

## LIVE rows the reference-app campaign must establish

The rows below are `LIVE` and are **not** established by any local run. The
reference-app campaign (`examples/pluto` / the scaffolded workspace on a real
target) must observe each of them; a row stays `UNQUALIFIED` until then.

**A Kubernetes cluster with the observability stack (the repo's `sol local deploy`):**

- OB-L2 — `sol logs`' `kubectl` fallback delivering real pod logs when Loki is
  unreachable.
- OB-M2 — the six taxonomy labels on a real *scraped* series (pod-label
  promotion by the pinned Prometheus chart), including a `-fn` Pushgateway push
  carrying the same labels.
- OB-T3 (deployed half) — a pod whose `<name>-env` ConfigMap supplied `SOL_*`
  (not a manually-set process environment); its trace resource carries the six
  and its `service` equals the pod label.
- OB-T4 (deployed half) — a single trace whose spans carry two different
  `resource.domain` values (two units, each with its own ConfigMap) resolving
  under both units' `sol open traces` queries.
- OB-D1/OB-D2 — dashboard panel data under the cluster's scrape labels, and a
  panel that reads its authoritative source.
- OB-S1 — workload health derived from Kubernetes (`ready`, `unhealthy` with the
  cause named), not only the `UNKNOWN` case.
- OB-S2/OB-S4 — the deployed backend's reachability and `sol open`'s base-domain
  path, including the explicit port-forward message.
- OB-S6 — the documented day-two path stays inside Sol.
- OB-F1 — the specific `SolTelemetryTargetDown` firing from a `monitoring`
  scrape that can go down.
- OB-F4 — `SolRolloutFailed` on a rollout that never becomes available, and the
  Kubernetes/backend detail view.
- OB-O1 — the full deploy → failure → diagnose → rollback → recovery loop.

**Operator-gated (not automatable here):**

- OB-F1 (delivered-and-acknowledged) — the named owner confirms receipt of the
  alert; HARDEN-002 evidence, not a command's exit status.

**A cloud target (AWS `self_hosted_durable` / an external endpoint):**

- OB-M3 — managed-resource facts surfaced from the provider's own system
  (CloudWatch), never mirrored.
- OB-R2 — `self_hosted_durable` keeps logs and metrics across teardown
  (S3/Thanos, `prevent_destroy`).
- OB-R3 — `external` ships logs/metrics and `sol logs --loki-base-url` reads
  them back.

The cross-signal check the campaign should make explicit: one request's Loki
line, Prometheus series and Tempo trace all carry the same
`workspace`/`env`/`domain`/`service`/`primitive`/`release` values.


