---
id: INFRA-027
type: feature
severity: medium
title: Provide infrastructure observability at target scope without unifying the telemetry source
source: Sol Unified Operational Interface design review, 2026-09-18
---

**Depends on:** DEC-032.

**Related:** DEC-031, OBS-044, FEAT-090.

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
