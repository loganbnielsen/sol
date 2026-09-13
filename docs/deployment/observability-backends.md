# Observability Backends

`cli/platform/infra/base`'s `observability_backend` variable selects where Loki
(logs) and Prometheus (metrics) data lives. Sol ships a self-hosted durable
path so production users are not forced into Sol-hosted observability.
The product design is documented in
[`docs/architecture/observability-design.md`](../architecture/observability-design.md).

| Profile | Logs (Loki) | Metrics (Prometheus) | Requires |
|---|---|---|---|
| `local` (default) | In-cluster, optional PVC | In-cluster, optional PVC | Nothing. For dev and throwaway clusters. |
| `external` | Skipped entirely; Alloy ships straight to your endpoint | Still runs (it's the scrape agent) but forwards via `remote_write`, short local retention | `external_loki_url` + `external_prometheus_remote_write_url` (and usernames/passwords if your endpoint needs basic auth) |
| `self_hosted_durable` | In-cluster Loki, chunks + index in S3 | Prometheus + Thanos sidecar/storegateway/compactor backed by S3 | AWS only — see below |

Log shipping is [Grafana Alloy](https://grafana.com/docs/alloy/latest/)
(OBS-039), the officially documented successor to Promtail — Promtail
itself reached end-of-life in March 2026. A cluster-wide DaemonSet tails
every pod's stdout/stderr via the Kubernetes API
(`loki.source.kubernetes`, no hostPath mount required) and relabels
standard Kubernetes metadata plus Sol's taxonomy labels
(`workspace`/`domain`/`service`/`primitive`/`release`) onto each log
stream, the same taxonomy `render_taxonomy_labels` already applies to pod
labels. Alloy's scope in Sol today is log shipping only — its
metrics/traces collection capability is unused, tracked separately for
`OBS-041`'s tracing work.

## `external`

Points Alloy's log-shipping target and Prometheus's `remote_write` at
infrastructure you already run or already pay for (a hosted Loki/Prometheus
service, your own observability stack elsewhere, etc.). Sol's Grafana +
local Loki are skipped since there's nothing local left to browse; Prometheus
itself keeps running because it's the thing doing the scraping, just with a
couple hours of local retention instead of the usual 15 days.

```hcl
observability_backend                = "external"
external_loki_url                    = "https://logs-prod-000.grafana.net/loki/api/v1/push"
external_loki_username               = "123456"
external_loki_password               = "<api key>"
external_prometheus_remote_write_url = "https://prometheus-prod-000.grafana.net/api/prom/push"
external_prometheus_username         = "123456"
external_prometheus_password         = "<api key>"
```

For read-side log snapshots, pass a Loki query URL and credentials to
`sol logs --no-follow`:

```bash
export SOL_LOKI_USERNAME="123456"
export SOL_LOKI_PASSWORD="<api key>"

sol logs --scope payments/charge_svc \
  --no-follow \
  --observability-backend external \
  --loki-base-url https://logs-prod-000.grafana.net
```

`--loki-username`/`--loki-password` are also supported for one-off use, and
flags win over `SOL_LOKI_USERNAME`/`SOL_LOKI_PASSWORD` when both are set. Prefer
`SOL_LOKI_PASSWORD` on shared hosts because command-line flags can be visible in
shell history and process listings.

## `self_hosted_durable` (AWS only)

Production self-hosted observability in the user's AWS account.
Object-storage-backed Loki keeps logs in S3. Prometheus writes blocks through
a Thanos sidecar; Thanos Query reads current blocks from the sidecar and
historical blocks from storegateway, with compactor managing object-store
block growth. GCP is a deliberate gap, not an oversight: it uses AWS IRSA to
grant Loki/Thanos access to S3, which has no meaning on a non-EKS cluster.

`cli/platform/infra/base`'s `cloud_provider` variable (default `"aws"`) makes
this explicit and enforced. Applying `self_hosted_durable` with
`cloud_provider = "gcp"` fails fast at `terraform apply` with a clear
`self_hosted_durable`-is-AWS-only error instead of silently installing a
meaningless IRSA annotation on a GKE cluster. GCS bucket + Workload Identity
support is tracked separately in INFRA-003, not built speculatively here.

The gate only protects you if `cloud_provider` truthfully reflects your
cluster — since it defaults to `"aws"`, an unset value looks identical to
actually being on AWS. A GKE (or any non-EKS) cluster operator should
always pass `cloud_provider = "gcp"` explicitly, regardless of which
`observability_backend` profile they pick, so this check (and any future
provider-specific one) actually applies to their cluster.

This is two Terraform states with no automatic link between them (same as
`cert_manager_irsa_role_arn` already works): apply `cli/platform/infra/aws` with
durable observability enabled, read its outputs, then pass them into
`cli/platform/infra/base`.

```bash
# cli/platform/infra/aws
terraform apply \
  -var=enable_durable_observability=true \
  -var=loki_retention_days=90 \
  ...

terraform output loki_s3_bucket      # -> loki_s3_bucket
terraform output loki_irsa_arn       # -> loki_irsa_role_arn
terraform output thanos_s3_bucket    # -> thanos_s3_bucket
terraform output thanos_irsa_arn     # -> thanos_irsa_role_arn
```

```hcl
# cli/platform/infra/base
observability_backend = "self_hosted_durable"
cloud_provider        = "aws" # required to stay "aws" for this profile
aws_region            = "us-east-1"
loki_s3_bucket        = "<from loki_s3_bucket output>"
loki_irsa_role_arn    = "<from loki_irsa_arn output>"
thanos_s3_bucket      = "<from thanos_s3_bucket output>"
thanos_irsa_role_arn  = "<from thanos_irsa_arn output>"

prometheus_raw_retention_days = 90
thanos_retention_5m_days      = 90
thanos_retention_1h_days      = 90
```

**What it costs:** S3 storage plus the in-cluster Loki, Prometheus, Thanos
Query, storegateway, and compactor pods. The Loki bucket has a 90-day
expiration lifecycle rule by default; set `loki_retention_days` in
`cli/platform/infra/aws` to change log retention. Thanos metric retention is owned
by the compactor, not an S3 lifecycle rule. Set
`prometheus_raw_retention_days`, `thanos_retention_5m_days`, and
`thanos_retention_1h_days` in `cli/platform/infra/base` to change metric
retention.

**Teardown:** the Loki and Thanos S3 buckets use Terraform `prevent_destroy`
so retained logs and metrics are not deleted as part of a cluster teardown.
To intentionally delete them, remove that lifecycle guard and empty/delete the
buckets explicitly.

**Why Thanos over Mimir (OBS-007):** the write path bolts onto the Prometheus
deployment Sol already runs, and the read path only needs Query,
storegateway, and compactor. Mimir can come later if ingestion scale demands
it.

**Known gap:** the full S3-backed path has not been exercised against a live
cluster. This pass is still static Terraform/Helm validation only; run a real
AWS deploy before depending on it in production.

## Alerting (OBS-040)

All three profiles ship the same starter Alertmanager + rule set — Sol uses
the plain `prometheus-community/prometheus` chart (`server` +
`alertmanager` subcharts), not the Prometheus Operator, so there is no
`PrometheusRule` CRD here. Rules and Alertmanager routing are both plumbed
in as chart `values` in `cli/platform/infra/base/main.tf`'s
`helm_release.prometheus`, the same way `remoteWrite`/Thanos fields are
today:

- `serverFiles."alerting_rules.yml"` — Prometheus's own alerting-rule file
  (`groups: [...]`), rendered to `/etc/config/alerting_rules.yml` and
  wired into `prometheus.yml`'s `rule_files` by the chart's default.
- `alertmanager.config` — the bundled `alertmanager` subchart's own
  `route`/`receivers` config (confirmed via `helm show values
  prometheus-community/prometheus --version 25.20.1`; older docs and
  older chart versions used a different key, `alertmanagerFiles`, which
  this pinned version does not read).

### Starter rules

Both rules use Sol's label taxonomy
(`workspace`/`env`/`domain`/`service`/`primitive`) or standard
kube-state-metrics labels — never a hardcoded domain/service — so they
apply workspace-wide to every deployed service by default.

| Alert | Signal | Threshold |
|---|---|---|
| `SolHighErrorRate` | `sol_svc_requests_total{status_class="5xx"}` vs total, from `-svc`'s auto-metrics (same metric as the "5xx error rate by service" dashboard panel) | 5xx ratio > 5%, sustained 5 minutes, grouped by `workspace, env, domain, service` |
| `SolPodRestartLoop` | `kube_pod_container_status_restarts_total` (kube-state-metrics, bundled and scraped by this chart by default) | more than 3 restarts in 15 minutes, sustained 5 minutes, per `namespace, pod, container` |

`SolPodRestartLoop` alerts on kube-state-metrics' own `namespace`/`pod`/
`container` labels rather than Sol's taxonomy labels directly — those live
on the *monitored* pod, not on kube-state-metrics' own pod. Sol namespaces
are named `<workspace>-<domain>` (`Sol_cli_kubernetes_name.namespace_of_parts`),
so the alert is still workspace/domain-identifiable from `namespace` alone.
For an exact `service`/`primitive` breakdown, join with the
`kube_pod_labels` metric (requires enabling kube-state-metrics'
`metricLabelsAllowlist` for pod labels — not configured by default, since
it isn't needed for the alert itself).

**Deploy-failure alert: skipped for v1.** `OBS-037` added `sol deploy`'s
release-event line, but it's a *Loki log line*
(`cli/sol/lib/sol_cli_deploy_event.ml`), not a Prometheus metric —
Prometheus alerting rules can't query Loki. There is currently no metric
derived from deploy events (no Pushgateway push, no counter), so there's
no Prometheus-queryable signal to alert on yet. Revisit once a deploy
health metric exists (e.g. a Pushgateway push from `sol deploy` on
rollout success/failure); until then, use `sol logs` or a Grafana Loki
panel to check deploy outcomes manually.

### No receiver configured by default

Alertmanager ships with a `null` receiver and no `route.receiver` pointing
anywhere real — alerts fire and are visible in Alertmanager's own UI/API,
but nothing is notified. This is deliberate: Sol doesn't know your Slack
webhook, PagerDuty key, or on-call email, so it doesn't guess one.

To wire up a real receiver, override `alertmanager.config` in
`cli/platform/infra/base/main.tf`'s `local.prometheus_alertmanager_config` (or
pass an additional `helm_release.prometheus` `values` entry that
deep-merges over it) with the shape the `alertmanager` chart expects — see
`helm show values prometheus-community/alertmanager --version 1.10.0` for
the full schema. For example, a Slack receiver:

```hcl
receivers = [
  { name = "null" },
  {
    name = "slack"
    slack_configs = [{
      api_url    = var.slack_webhook_url
      channel    = "#alerts"
      send_resolved = true
    }]
  }
]
route = {
  receiver = "slack" # was "null"
  # ...
}
```

PagerDuty (`pagerduty_configs`) and email (`email_configs`) receivers
follow the same `alertmanager.config.receivers[].<type>_configs` shape.
None of these are built here — this is the extension point, not a shipped
integration (see OBS-040's ticket non-goals).

### Extending the rule set

Add more alerting rules the same way: extend
`local.prometheus_alerting_rules.groups[0].rules` (or add another group)
in `cli/platform/infra/base/main.tf`. Multi-window burn-rate alerting and
SLO-based rules are a deliberate non-goal for this starter set — Sol has
no per-service SLO target concept today: revisit only if the simple
threshold rules above prove insufficient in practice.

## Dashboards (OBS-011, OBS-036, OBS-038)

All three profiles provision the same four Grafana dashboards, loaded via
the standalone `grafana` chart's sidecar ConfigMap-loading
(`sidecar.dashboards`) rather than one file per domain/service:

- **Workspace overview** — request rate, 5xx rate, and scraped-target health
  across every domain at once.
- **Service template** — one dashboard parameterized by `$domain`/`$service`
  Grafana template variables (populated live from Prometheus label values,
  not a list Sol maintains). Selecting values re-scopes every panel,
  including a Loki logs panel filtered to that domain/service.
- **Domain overview** (OBS-036) — one dashboard parameterized by `$domain`
  only (no `$service`), showing the same request rate / 5xx rate /
  scrape-target health signals broken down per service within that domain,
  plus a Loki logs panel filtered to that domain. Fills the gap between the
  workspace-wide and single-service views for a domain-level incident.
- **Release timeline** (OBS-038) — a Loki logs panel showing `sol deploy`'s
  `event=deploy` log lines (OBS-037), filtered by the same `$workspace`/
  `$domain`/`$service` template variables as the other dashboards. Those
  deploy-event lines are pushed directly by the `sol` CLI rather than
  tailed from a pod (`cli/sol/bin/cmd_deploy_event.ml`), but carry real
  Loki stream labels the same way an application pod's own logs do:
  `service` is the deployed service's real name (`Obs_eio.create`'s
  built-in stream label), and `workspace`/`domain`/`primitive`/`release`
  are promoted from context the same way Alloy promotes them for
  application pod logs. Deploy events land in that service's own Loki
  stream rather than a separate one, distinguished from its ordinary
  application logs by the `event="deploy"` logfmt field every deploy-event
  line carries.

A Prometheus datasource is provisioned the same way the chart already
auto-provisions its own "Loki" datasource (a ConfigMap labeled
`grafana_datasource: "1"`), since nothing wired Grafana to Prometheus before
this ticket.

**Known gaps:**
- `-svc` and `-worker` primitives both get a `prometheus.io/scrape`
  annotation and a real metrics port (`-worker`'s closed by OBS-035), so the
  service template's `$service` dropdown populates for both. `-fn` uses
  Pushgateway, a different ingestion path neither ticket touches.
- A per-service **logs view** dashboard (mentioned in
  `docs/architecture/observability-design.md`) is not built — the service
  template's embedded Loki logs panel (filtered to `$domain`/`$service`)
  covers this use case in practice; see OBS-036's ticket for the reasoning.
- **Not verified against a live Grafana instance.** This pass validated the
  dashboard JSON is well-formed and the Terraform/Helm wiring
  (`terraform validate`, chart values checked against `helm show values`),
  but did not run a real `sol dev up` and confirm the panels/variables
  actually render and populate. Flagged explicitly — do this before trusting
  the dashboards in a real review.

## Tracing (OBS-042)

Tempo is the fourth backend, deployed the same way as Loki/Prometheus/
Grafana: `helm_release.tempo` (`grafana-community/tempo`, gated by
`local.loki_install_local`, the same condition Loki/Grafana already use —
no local Tempo to receive spans from when there's no local Grafana to
browse them in either) plus a Grafana datasource ConfigMap
(`kubernetes_config_map.grafana_tempo_datasource`) loaded through the same
sidecar convention as the others. `sol dev up` mirrors this exactly via
direct `helm`/`kubectl` calls in `cmd_local.ml` and
`Sol_cli_dev_observability.ml`, so local dev and Terraform-provisioned
clusters both get tracing the same way ("Dev mirrors prod exactly").

**Wired for `-svc`, `-worker`, and `-fn` alike, through `Sol_obs`.**
`obs-tempo-eio` (OBS-041) is composed in by `Sol_obs.of_env`
(`framework/sol-obs`, CODE_LAYER-003) whenever `TEMPO_URL` — an optional
environment variable following the same pattern as `LOKI_URL` — is set;
absent means no traces, not a startup failure. Since every scaffolded
primitive now bootstraps its `Obs_eio.t` through the same `Sol_obs.of_env`
call rather than composing providers by hand per template, Tempo wiring is
no longer `-svc`-specific: `-worker` and `-fn` scaffolds pick it up
automatically too, closing the gap `OBS-035`'s one-primitive-at-a-time
precedent had left open.

**Two ports, two purposes.** Spans push to Tempo's OTLP/HTTP receiver on
port 4318 (`TEMPO_URL`, what `-svc` and `examples/local-demo`'s order-svc
push to); Grafana's Tempo datasource reads from Tempo's own query API on
port 3200. `sol dev up` port-forwards both (`tempo` and `tempo-query`).

**Trace-lookup link.** The Loki datasource (both
`kubernetes_config_map.grafana_loki_datasource` in Terraform and
`Sol_cli_dev_observability.loki_datasource_yaml` in `sol dev up`) carries a
`derivedFields` entry matching `obs-loki-eio`'s real `trace_id=` logfmt
output (an unquoted 32-hex-char field), so a `trace_id` in any Loki log
line is clickable through to its Tempo waterfall. A dedicated
trace-analysis dashboard is a non-goal for this ticket — this is the
minimal "log line to trace" link, not an APM-style trace search UI.

**Verified live**, not just statically: `dune exec
examples/local-demo/bin/demo.exe` with `TEMPO_URL` set produced real spans
in a real local Tempo instance (`cli/platform/local/scripts/ensure-tempo.sh`),
confirmed via `curl`'s TraceQL search API
(`/api/search?q={resource.service.name="order-svc"}`) — and the `trace_id`
captured in the corresponding Loki log line matched a real Tempo trace ID
byte-for-byte, confirming the derivedFields regex and encoding actually
line up. `helm_release.tempo`'s chart/version was also confirmed with a
real `helm install --dry-run=server` and a real (non-dry-run) install
against a live k3d cluster.

**Known gap:** the Tempo datasource ConfigMap's sidecar pickup was not
verified against a live Grafana UI click-through in this pass (the shared
local test cluster's existing Grafana predates OBS-039's chart split) —
the underlying trace_id/regex/datasource-uid mechanism was verified against
real data as above, but "click a log line and land on the trace in
Grafana's UI" itself was not visually confirmed. Do this before trusting
the click-through in a real review.
