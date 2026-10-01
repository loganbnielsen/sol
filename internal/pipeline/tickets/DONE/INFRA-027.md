---
id: INFRA-027
type: feature
severity: medium
title: Provide infrastructure observability at target scope without unifying the telemetry source
source: Sol Unified Operational Interface design review, 2026-09-18
---

**Depends on:** DEC-032.

**Related:** DEC-031, OBS-044, FEAT-090.

**Promoted to `READY_FOR_ENGINEERING` on 2026-09-18:** `DEC-032` is decided and on
`main`, so the architectural prerequisite this was waiting for is settled — a
target is an axis, not a scope, and an infrastructure view is addressed by target
with no application scope. Nothing else was blocking it; this is the bookkeeping
transition, not a new decision.

The surface syntax is now settled too: `DEC-031` fixed the rule (the command's
primary axis takes the positional), so an infrastructure view addressed by target
takes the target positionally, the same way `sol cloud plan|apply|destroy` already
do.

## What this is

The review asks for observability of the infrastructure a target runs on:
Kubernetes/node health and capacity, Postgres health and capacity, Kafka/Redpanda
health, observability-infrastructure health, platform resource utilization, and
the relevant infrastructure alerts.

Today only one narrow slice exists. Managed datastores Sol provisions itself are
covered by OBS-044's generic managed-resource dashboards
(`resource/<type>/<name>`, RDS first), which are CloudWatch-backed. Nothing covers
nodes, Redpanda, Postgres, or the observability stack itself, and there is no
target-scoped entry point that gathers them.

Two things this ticket must **not** do:

1. **It must not pick a single telemetry backend.** The product-level contract is
   that Sol owns an infrastructure-observability *capability and its navigation*,
   while the appropriate telemetry source may differ per resource. RDS metrics
   being CloudWatch-backed while Kubernetes/node, Redpanda and Postgres metrics
   are Prometheus-backed is not inherently inelegant — that is the same
   separation the review already draws between CLI and Grafana, and between Sol's
   model and the systems that own individual facts. The requirement is that the
   target-scoped infrastructure view takes a user to the right thing; unified
   semantics do not require unified storage.
2. **It must not add one-off dashboards per resource.** OBS-044's mechanism is
   deliberately generic over resource type
   (`cli/platform/infra/base/dashboards/managed-resource.json.tftpl` plus
   `local.managed_resources` in `cli/platform/infra/aws/main.tf`). Extending that
   pattern is in scope; a second bespoke dashboard per component is not. Where a
   component genuinely does not fit the pattern, the ticket says why rather than
   silently forking it.

The entry point's surface syntax is DEC-032's to settle (target as a separate
axis from scope, optionally with an infrastructure view). This ticket consumes
that decision; it does not invent one.

## Evidence (2026-09-18, `main` at 790dc3e8)

Provisioned dashboards today, all in `cli/platform/infra/base/dashboards/` and
wired from `cli/platform/infra/base/main.tf:922-925`:

| Dashboard | Covers |
|---|---|
| `workspace-overview.json` | application workspace |
| `domain-overview.json` | application domain |
| `service-template.json` | application unit |
| `release-timeline.json` | release/deploy timeline |
| `managed-resource.json.tftpl` | managed datastore (RDS via CloudWatch, OBS-044) |

All four application/managed dashboards are application or datastore scoped.
There is no node/capacity, Redpanda, Postgres, or observability-infrastructure
dashboard, and `sol open` exposes no target-scoped view. The components the
platform already runs and readiness-checks — Prometheus, Loki, Tempo, Thanos,
Redpanda, ingress-nginx, cert-manager, Argo CD, Alloy, per
`Sol_cli_cloud_lifecycle.readiness` — have no dashboard entry point at all.

## Non-goals

- Not choosing a single metrics backend, and not migrating CloudWatch-backed
  resources into Prometheus (or the reverse).
- Not replacing the provider consoles. Grafana stays a projection, and the raw
  console stays reachable.
- Not a bespoke Sol UI, and not a fork or white-label of Grafana.
- Not the target-status summary (FEAT-090) or the lifecycle phase, which ADR 0003
  already defines.
- Not alert routing or delivery — see FEAT-092 for the per-scope alert question.

## Acceptance criteria

- A target-scoped infrastructure view surfaces node health and capacity, Postgres
  health and capacity, Kafka/Redpanda health, observability-infrastructure
  health, and platform resource utilization.
- Each surface names which telemetry source backs it; more than one source is
  expected and acceptable, and the view does not pretend otherwise.
- Resources Sol provisions plug into the OBS-044 map/template pattern rather than
  requiring a bespoke dashboard, and any component that does not fit states why.
- Dashboard variables used for navigation resolve from live values (the
  label/dimension convention the application and managed-resource dashboards
  already use), not from a hand-maintained list.
- An advanced user can drop into plain Grafana, Prometheus, or the provider
  console from the same entry point.
- The view resolves for a target that has no application deployed to it, since
  infrastructure observability does not depend on a scope.

**Demo/example coverage:** Dashboards are user-facing, so at least the local
substrate path (`sol local infra up` and its generated Grafana config) must
demonstrate the view end to end, with the cloud path's differing telemetry source
stated explicitly.

**TypeScript parity:** No language-parity impact — infrastructure observability
does not touch the application contract.

## Completion (2026-10-01)

Implemented on `INFRA-027/target-infrastructure-view`, based on `main` at `69035715`.

**Premise verified (`main` at `69035715`), still actionable.** `Sol_cli_open.kind` had no
`Infra` case and `sol_cli_open.ml` never mentioned a target; the only dashboards were the
four application/managed ones:

```text
$ rg -n 'Infra' cli/lib/deploy/sol_cli_open.ml cli/bin/cmd_open.ml
(no match)
$ ls platform/shared/observability/dashboards/
domain-overview.json  managed-resource.json.tftpl  release-timeline.json
service-template.json  workspace-overview.json
```

**Every telemetry claim below was observed, not assumed.** A local substrate
(`k3d-sol-local`, 15 days old) was running, so the sources were read directly rather than
inferred from the charts:

```text
$ kubectl --context k3d-sol-local -n monitoring port-forward svc/prometheus-server 19090:80
$ curl -s 'localhost:19090/api/v1/targets?state=active' | jq -r '.data.activeTargets[].labels.job' | sort -u
kubernetes-apiservers  kubernetes-nodes  kubernetes-nodes-cadvisor  kubernetes-pods
kubernetes-service-endpoints  prometheus  prometheus-pushgateway
```

`up` by job gives the same seven. `kube_node_status_condition`, `kube_node_status_capacity`,
`kube_pod_status_ready`, `container_memory_working_set_bytes` and
`container_cpu_usage_seconds_total` all return series, so node health/capacity,
observability-infra health and platform utilization already had a Prometheus source.
`redpanda_*` and `pg_*` returned **nothing** — the two surfaces the AC names had no
telemetry at all:

```text
$ curl -s localhost:19090/api/v1/label/__name__/values | jq -r '.data[]' | rg -c '^(redpanda_|pg_)'   # 0
$ kubectl --context k3d-sol-local -n redpanda port-forward pod/redpanda-0 19644:9644
$ curl -s localhost:19644/public_metrics | rg -c '^redpanda_'                                        # 2110
```

Chart capabilities were read from the charts themselves (`helm show values`), not guessed:
bitnami `postgresql` 18.8.17's `metrics.enabled` starts postgres-exporter and gives its
Service the `prometheus.io/scrape`/`scrape.io/port` annotations the chart's default
`kubernetes-service-endpoints` job looks for; Redpanda 26.1.11's
`statefulset.podTemplate.annotations` is the supported hook, since its `monitoring.enabled`
ServiceMonitor needs prometheus-operator, which Sol does not run.

**What landed.**

- `platform/shared/components.json` — `postgresql.common.metrics.enabled` and the three
  Redpanda pod annotations, so both surfaces have a Prometheus source in local and cloud.
- `platform/shared/observability/dashboards/target-infrastructure.json` — one target-scoped
  dashboard whose row titles name the source: nodes (kube-state-metrics and the kubelet),
  platform utilization (cAdvisor), the observability stack (`up` and kube-state-metrics),
  Redpanda (its public metrics), Postgres (postgres-exporter). Every PromQL expression was
  run against the live Prometheus (all return series today); the two that cannot until the
  exporters above deploy are the Redpanda and Postgres panels.
- `Sol_cli_open.Infra` plus `validate`/`requires_target`, and `sol open infra`, which
  requires `--target` and refuses a scope by name (`DEC-031`, `DEC-032`):
  `Sol_cli_open.scope` did not gain a target case. The subcommand prints the dashboard URL
  and the target's provider console.
- `Sol_cli_provider_capabilities.provider_console_url` — provider-owned: AWS by region, GCP
  by project (and no console when the target declares none, rather than a URL that would
  404).
- Provisioned on both paths: `Sol_cli_dev_observability.dashboard_names` (local) and the
  `sol-grafana-dashboards` config map in `platform/cloud/modules/platform/main.tf` (cloud).

**Two design points worth recording.**

1. **The surface syntax is `sol open infra --target T`, not a positional target.** This
   ticket's promotion note said the target would be positional, but `DEC-031` and `DEC-032`
   decide the opposite and are later: `sol open` is addressed *by scope*, so the view is a
   subcommand and every other axis is a flag, and `DEC-032` explicitly says
   `Sol_cli_open.scope` gains no target case. The infrastructure view therefore has no
   scope and takes `--target`; `sol open infra payments` fails naming it target-scoped.
2. **No per-resource dashboard was added.** RDS and any other managed datastore stay on
   `OBS-044`'s generic CloudWatch-backed managed-resource dashboard — one template per
   resource *type*, not per resource — and the infrastructure dashboard links to it. The
   only component that does not fit that pattern is the in-cluster Postgres, which is not a
   managed resource and is read through postgres-exporter instead; the dashboard says so.

**Demo/example coverage.** The local path is the runnable artifact the AC names: the
generated Grafana config is asserted to carry the dashboard
(`cli/test/test_dev_observability.ml`) and to enable both exporters, and the cloud path's
differing source (a managed database on the provider's metrics service) is stated in the
dashboard's own text panel and in `docs/guides/operations.md` §6, with the command-line
surface in `docs/reference/cli.md`. A live `sol local infra up` on a running local cluster
is the operator's end-to-end demonstration; the two exporter changes take effect on that
deploy and were not re-deployed from this session because restarting the operator's
Postgres and Redpanda is their call, not a test's.

**Validation.** `dune build`; `dune test cli/` (including the new
`cli/test/test_open_infra.sh` end-to-end rule and the dashboard-configmap assertions);
`internal/ci/check_ocamlformat.sh --all`, `check_no_comments.sh`, `check_result_syntax.sh`,
`check_cli_reference.py` (regenerated), `check_test_reachability.py`,
`check_provider_dispatch.sh`, `check_library_output.sh`,
`check_platform_component_drift.py`, `check_manifests_are_values.sh` and
`check_examples_self_contained.sh` all pass.

**TypeScript parity:** No language-parity impact — infrastructure observability does not
touch the application contract.
