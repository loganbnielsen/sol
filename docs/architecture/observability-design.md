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

## One Model, Three Representations

`sol`, Grafana, and automation (CI, a script, an agent) are three *representations
of one model*, not three platforms with their own facts:

| Representation | What it is for |
|---|---|
| `sol status` / `sol logs` / `sol open` | The deterministic, greppable surface: scope resolution, health, and the command or URL that opens the right view. Works over SSH, in CI, and for an agent with no browser. |
| Grafana | The visual surface: rendering, exploration and time-series navigation over the same labels and the same dashboards Sol provisions. |
| Automation | The same model consumed without a human: `--links` output, the provisioned dashboard definitions, and the status output, all as data. |

A capability belongs to the model and appears in every representation; a
representation may expose less, but must not invent its own identity or its own
scope vocabulary. Concretely: a dashboard's template variables resolve the same
labels `sol status` accepts, and `--links` prints the URL for the same view
`sol open` would open.

Two capabilities are not in all three yet, and they carry their owner rather than
leaving the gap implied: **traces have no CLI surface** — `sol open` covers `logs`,
`metrics` and `dashboard` today, and OBS-045 owns the traces entry point — and
**alerts are not exposed per scope** (FEAT-092).

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
| `release` | Content-addressed release id (`r-<16 hex>`) — the join key from a deploy record to its telemetry. Not the image tag: one release can span several images. |

> **Status:** all six labels, including `env`, are emitted (OBS-008,
> `env` added by FEAT-026). `sol deploy <env>/<provider>/<region>` resolves
> the target via `Sol_cli_config.load_for_target` — the same path `sol
> plan`/`sol cloud tf` already used, and `sol status`/`sol logs`/`sol open`
> use for `observability_backend`/`base_domain` (OBS-015) — and threads
> `env = target.env` through to every generated manifest's labels. `sol
> up` stays local-only by design (no target, no `env` label — it's omitted
> there, not defaulted to a fake value like `"local"`).
>
> `release` is the plan's content-addressed identity (`Release_id.of_content`,
> FEAT-069) and is written verbatim — the same id `sol releases` lists and
> `sol logs --release` queries.
>
> A deployment *event* (FEAT-070) is the separate object: its own minted
> `deployment_id` (`d-<YYYYMMDDtHHMMSSz>-<16 hex>`) plus provenance and an
> `outcome` (`applied` / `apply_failed`), recorded as an immutable
> `sol-deployment-<id>` ConfigMap and listed by `sol deployments`.
> The deploy marker pushed to Loki carries the same `deployment_id` as a logfmt
> *field* (not a stream label — it varies per invocation), which is the join key
> from the observability timeline to the authoritative record; it is emitted only
> once that record has been persisted, so the marker never advertises a join to a
> record that does not exist. `deployment_id` never enters the pod template: it
> identifies the attempt, not the released state.
>
> **`release` is not a metrics dimension.** It is written into the pod template
> (so Loki can select it exactly) but never into a Prometheus label: releases
> accumulate forever, and a per-release time series would be unbounded
> cardinality. Metrics correlate to a release through deployment metadata
> (FEAT-070's deployment events / `sol deployments`) and the bounded workload
> labels already in this table.

These labels are the API. Kubernetes namespaces, pod names, Helm release
names, bucket names, and cloud resource names are implementation details.

## Who Is Authoritative For What

Sol supplies shared identity and navigation. It does not become the system of
record for a fact another system already owns, and it does not keep a second copy
of that fact where the two can drift apart:

| Information | System of record | Sol's role |
|---|---|---|
| What infrastructure exists | Terraform state (`sol cloud plan/apply`) | Read and present it; never keep a parallel inventory |
| What was released, and when | Sol release records (`sol releases`) and deployment events (`sol deployments`) | Own these — they are Sol's own facts, so nothing else is authoritative for them |
| What the applications emitted | The observability backend (Loki, Prometheus, Tempo, or an external provider) | Own the labels, definitions, scope mapping and links that make it navigable; never the raw storage |
| What the cloud provider measured | The provider's own metrics system (CloudWatch on AWS) | Surface it through a managed-resource dashboard (OBS-044) rather than duplicating it |

Stated plainly: when `sol status` reports health, it reports what the authoritative
system said. A number maintained in two systems is a number that will eventually
disagree with itself, and the observability surface is where that becomes visible
to a user at the worst moment.

**The target axis.** A *target* is not a scope. DEC-032 settled target, scope and
view as three separate axes, so an infrastructure view is addressed by target with
no application scope attached — the positional form DEC-031 fixed, the same one
`sol cloud plan|apply|destroy` already take. Extending the status surface with cloud
health, drift and last operation is **FEAT-090**; target-scoped infrastructure views
(nodes, Postgres, Redpanda, the observability stack itself) are **INFRA-027**.
Neither is claimed here as shipped.

## Lifecycle

Deploy and destroy move a target through named phases, and **ADR 0003**
(`adr/0003-lifecycle-phases-authority-and-policy.md`) owns that model: the phase
names, what each phase may change, and which authority applies during it. This
document does not restate the phases. Two documents stating one model is exactly
the failure this design's own product rule forbids, and the review that produced
this section proposed a different phase vocabulary than the accepted one — copying
it here would have created the contradiction it was meant to remove.

The one principle worth repeating, because it is about observability: **the phase
is not infrastructure truth.** A phase says which mutations are allowed and which
authority applies; it does not say what exists. That answer comes from the system
of record in the table above, which is why a phase transition must never stand in
as a proxy for "the infrastructure is in state X".

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

Grafana is the default self-hosted dashboard shell today. Sol provisions one
workspace dashboard entrypoint plus scoped dashboards, as JSON in the tree:

- workspace overview — `platform/infra/base/dashboards/workspace-overview.json`
- domain overview — `dashboards/domain-overview.json`
- service dashboard for service-specific metrics — `dashboards/service-template.json`
- service logs view — Loki-backed log panels inside the dashboards above, plus the
  scoped `sol open logs` link; not a separate file
- deploy/release timeline — `dashboards/release-timeline.json`

All four files are provisioned by `platform/infra/base/main.tf`.

The dashboard should filter by Sol labels, not by namespace/pod names. A
single incident often crosses an HTTP service, Kafka worker, scheduled
function, database, and deploy event — cross-domain search is the point.

### What Sol owns, what Grafana owns

The split is narrow on purpose, and it is what keeps Grafana a choice rather than a
dependency:

| Sol owns | Grafana owns |
|---|---|
| Dashboard *definitions* — the JSON above, provisioned from the tree | Rendering them |
| The telemetry label and attribute vocabulary (`workspace`, `env`, `domain`, `service`, `primitive`, `release`) | Label storage — Loki, Prometheus and Tempo stay the systems that hold the data |
| Template variables and the scope -> label mapping they resolve | The variable UI and query editing |
| Deep links, and the `sol open <view> <scope>` -> URL mapping | Navigation inside a panel or a time range |
| Provisioning: datasources, dashboards, folders | Exploration: ad-hoc queries, zooming, panel edits |

Sol does not implement a bespoke frontend, fork Grafana, or white-label it, and no
capability is defined in a way that only a Grafana-specific feature could satisfy
(see Non-Goals). If the renderer were replaced, the definitions and the labels would
still be the model; only the renderer would change.

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

> **No ticket owns this section.** It records a product direction, not a committed
> deliverable: there is no hosted Sol today, so nothing here should be read as
> scheduled work or as a promise about a future release. When the hosted path is
> taken up it gets a ticket, and that ticket owns the design.

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
- No second system of record. Sol does not mirror Terraform state, the
  observability backends' raw data, or the cloud provider's metrics as its own
  copies; it reads them and supplies the identity and navigation over them.
- No becoming the composition. Sol does not become Terraform, Kubernetes,
  Grafana, Prometheus, Loki, or Tempo. It composes them, owns the model that makes
  them one surface, and leaves each to be the expert in its own job — which is the
  same separation the CLI/Grafana split above describes.
