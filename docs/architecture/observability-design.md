# Observability Design

Sol treats observability as a workspace-level capability, not a per-service
add-on. A Sol workspace belongs to one company/product; domains (team-owned
verticals, e.g. `payments`, `comms`) inside it own the services, workers, and
functions that emit into the same observability surface.

The product rule is:

```text
one workspace -> one logs backend, one metrics backend, one dashboard surface
```

Individual domains and services are scoped views inside that surface,
selected by stable labels — the same convention `sol status`/`sol logs`
already use (`<domain>` or `<domain>/<service>`). A service can and should
have its own dashboard; it should not have its own isolated observability
stack.

> Earlier drafts of this doc introduced a `project` layer above `domain`
> (grouping multiple products/apps inside one workspace). Dropped: Sol's
> existing `domain` concept already means "team-owned vertical composed of
> services/workers/functions" (see `CLAUDE.md`'s "Teams own domains"), which
> is what `project` was actually describing. No new layer — `workspace ->
> domain -> service` is the whole model.

## Goals

- A developer can open one dashboard and inspect the whole workspace.
- A domain, service, worker, or function can be filtered without knowing
  Kubernetes names.
- Self-hosted users get the same shape as future Sol-hosted users.
- Sol commands point at the shared surface while opening scoped dashboards
  for domains and services.

## Identity

Every log line, metric, trace, deploy event, and generated dashboard link
must carry the same ownership identity:

| Label | Meaning |
|---|---|
| `workspace` | Company/product workspace name |
| `env` | Environment, for example `dev`, `staging`, `prod` — determined by which target the CLI is currently pointed at (kubeconfig context / deploy target), not a CLI path segment |
| `domain` | Business domain/team slice, for example `payments` |
| `service` | Service, worker, or function name |
| `primitive` | `svc`, `worker`, or `fn` |
| `release` | Deployed image/release identity when known |

> **Status:** all six labels, including `env`, are emitted (OBS-008,
> `env` added by FEAT-026). `sol deploy <env>/<provider>/<region>` resolves
> the target via `Sol_cli_config.load_for_target` — the same path `sol
> plan`/`sol cloud tf` already used, and `sol status`/`sol logs`/`sol open`
> use for `observability_backend`/`base_domain` (OBS-015) — and threads
> `env = target.env` through to every generated manifest's labels. `sol
> up` stays local-only by design (no target, no `env` label — it's omitted
> there, not defaulted to a fake value like `"local"`).

These labels are the API. Kubernetes namespaces, pod names, Helm release
names, bucket names, and cloud resource names are implementation details.

## Backend Modes

Sol supports three observability backend modes:

| Mode | Use |
|---|---|
| `local` | Dev and throwaway clusters. In-cluster Loki, Prometheus, and Grafana. No durability promise. |
| `self_hosted_durable` | Production self-hosting in the user's cloud account. Durable logs and metrics with object storage. |
| `external` | Bring-your-own observability provider. Sol ships logs/metrics to the configured endpoints. |

The mode changes storage and transport. It should not change the product
surface: `sol status`, `sol logs`, and `sol open` should keep using the same
workspace/domain/service scopes.

## CLI Shape

`sol status` is deterministic from any directory inside the workspace. The
current working directory is only used to find the workspace root.

```bash
sol status
sol status payments
sol status payments/charge-svc
```

At workspace scope, show an index:

```text
sol workspace

Domains
  payments   healthy
  comms      degraded
  logistics  not deployed

Observability
  backend  self_hosted_durable
  logs     healthy
  metrics  healthy

Open
  logs       sol open logs
  metrics    sol open metrics
  dashboard  sol open dashboard
```

At domain scope, show service health and the shared observability surface:

```text
payments  self_hosted_durable  healthy

Services
  charge-svc    healthy
  refund-svc    degraded

Observability
  logs       healthy
  metrics    healthy
  dashboard  healthy

Open
  logs       sol open logs payments
  metrics    sol open metrics payments
  dashboard  sol open dashboard payments
```

At service scope, open the service-specific dashboard and logs view:

```text
payments/charge-svc  healthy

Observability
  logs       healthy
  metrics    healthy
  dashboard  healthy

Open
  logs       sol open logs payments/charge-svc
  metrics    sol open metrics payments/charge-svc
  dashboard  sol open dashboard payments/charge-svc
```

`Open` entries are commands, not URLs. A `--links` flag can print raw URLs for
copying or automation:

```text
Links
  logs       https://grafana.acme.com/explore?...
  metrics    https://grafana.acme.com/d/...
  dashboard  https://grafana.acme.com/
```

## Dashboard Shape

Grafana is the default self-hosted dashboard shell today. Sol should provision
one workspace dashboard entrypoint plus scoped dashboards:

- workspace overview
- domain overview
- service dashboard for service-specific metrics
- service logs view
- deploy/release timeline when available

The dashboard should filter by Sol labels, not by namespace/pod names. A
single incident often crosses an HTTP service, Kafka worker, scheduled
function, database, and deploy event — cross-domain search is the point.

### Managed resource dashboards (OBS-044)

The tiers above cover application services (workspace/domain/service).
They do not cover managed infrastructure resources Sol provisions directly
on the user's behalf — RDS PostgreSQL today, and potentially other managed
datastores in the future. Those resources emit their own operational
signal (CPU, connections, storage, IOPS, ...) through the cloud provider's
own metrics system (CloudWatch on AWS), not through Sol's Loki/Prometheus
pipeline, but a user still shouldn't have to leave Sol for the raw provider
console to see it — that cuts against the "you shouldn't need to learn
AWS" positioning (`docs/architecture/PRODUCT_ARCHITECTURE.md`).

A **managed resource dashboard** is a fourth tier, scoped by
`resource/<type>/<name>` (e.g. `resource/rds/acme-prod-postgres`) rather
than by `workspace/domain/service`:

- `platform/infra/aws/main.tf` describes each managed resource generically
  (`local.managed_resources`: name -> `{resource_type,
  cloudwatch_namespace, dimension_name, dimension_value, metrics}`) and
  provisions a native CloudWatch dashboard per entry plus an IRSA role
  granting Grafana's own pod read access to CloudWatch metrics.
- `platform/infra/base/main.tf` provisions one Grafana dashboard per
  distinct `resource_type` (not per resource instance) from a single
  shared template (`dashboards/managed-resource.json.tftpl`), wired to a
  CloudWatch Grafana datasource. The dashboard's `resource` template
  variable resolves live via a CloudWatch `dimension_values()` query — the
  same live-label-driven templating philosophy the domain/service
  dashboards already use for Loki/Prometheus label values.
- `sol open dashboard resource/<type>/<name>` and `sol status` resolve and
  print this dashboard the same way they resolve workspace/domain/service
  scopes, via `Sol_cli_open`'s `Resource` scope variant.

The mechanism is generic by resource type, not RDS-specific: RDS is the
first (and, per OBS-044's scope, currently only) entry. A future managed
datastore (e.g. DynamoDB, if Sol ever provisions it directly) plugs into
the same map/template/CLI-scope pattern rather than requiring a second
one-off dashboard implementation.

## Hosted Path

Future Sol-hosted observability should keep the same shape:

```text
workspace/domain/service
```

Sol may operate the storage itself or broker a managed provider behind the
scenes. Users should not have to learn that backend in the happy path. The
self-hosted durable path exists to build trust and avoid lock-in; the hosted
path exists to remove operations work.

## Non-Goals

- No separate observability stack per service.
- No CLI wrapper around every Loki or Prometheus query feature.
- No product promise that `local` preserves history.
- No provider-specific UX as the core model.
- No `project` layer above `domain` — see the note under Goals.
