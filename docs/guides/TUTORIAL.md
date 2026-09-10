# Sol Tutorial

This tutorial walks through building and running a real multi-service application on Sol. By the end you will have two services deployed to a local Kubernetes cluster, talking to each other through Kafka, persisting data in PostgreSQL, and emitting structured logs and metrics visible in Grafana — without writing a single Kubernetes manifest or Helm chart.

---

## What Sol is

Sol is a production platform for OCaml services. It gives you three service primitives:

- **`-svc`** — a long-running HTTP service with routes, auth, and a `/healthz` endpoint
- **`-worker`** — a Kafka consumer that processes a typed event stream
- **`-fn`** — a scheduled function that runs on a cron expression

These primitives share a common observability layer (Loki for logs, Prometheus for metrics) and a storage layer (PostgreSQL). Sol wires all of it together at startup. You write the handler; Sol runs it.

The `sol` CLI scaffolds new services, manages the local development cluster, builds and deploys container images, and runs database migrations.

---

## Prerequisites

- k3d v5+ and Helm v3+
- Docker, kubectl
- `librdkafka-dev`, `libpq-dev`, `libpq5` (`sudo apt-get install -y librdkafka-dev libpq-dev libpq5`)

Install `sol` (Linux x86_64) — download the self-contained release bundle:

```bash
# Replace vX.Y.Z with the latest version from https://github.com/loganbnielsen/sol/releases
curl -L https://github.com/loganbnielsen/sol/releases/latest/download/sol-vX.Y.Z-linux-x86_64.tar.gz \
  | tar xz
export PATH="$PWD/sol-vX.Y.Z-linux-x86_64/bin:$PATH"   # add to ~/.bashrc or ~/.zshrc
```

The tarball includes the `sol` binary and the framework source tree (`framework/`). No `SOL_HOME` or separate clone required — `sol new workspace` resolves the framework source automatically from the bundle layout.

> **Build from source:** Contributors who need `soldev` or want to modify the framework should clone the repo and build:
> ```bash
> git clone https://github.com/loganbnielsen/sol.git ~/sol
> export SOL_HOME=~/sol   # add to ~/.bashrc or ~/.zshrc
> eval $(opam env)  # requires OCaml 5.4.1 + opam
> dune build cli/
> ln -sf "$(pwd)/_build/default/cli/sol/bin/main.exe" ~/.local/bin/sol
> ln -sf "$(pwd)/_build/default/devtools/soldev/bin/main.exe" ~/.local/bin/soldev
> ```

---

## Part 1 — Local infrastructure

Sol's local cluster mirrors production exactly: same Helm charts, same service DNS names, same security model. The only difference is scale (single replica, no persistent volumes).

```bash
sol dev up
```

This creates a k3d cluster named `sol-local` and installs:

| Component | What it does |
|-----------|-------------|
| Redpanda | Kafka-compatible broker + schema registry |
| PostgreSQL | Primary database |
| Loki + Grafana | Log aggregation and dashboards |
| Prometheus + Pushgateway | Metrics collection |

When it finishes, every component is reachable on localhost:

```
Kafka           localhost:9092
Schema registry localhost:8081
PostgreSQL      localhost:5432
Loki            localhost:3100
Grafana         localhost:3000   (admin / dev)
Pushgateway     localhost:9091
```

These port-forwards are managed by Sol in the background (PIDs recorded in `~/.local/share/sol/`). `sol dev down` tears everything down. Running `sol dev up` again clears any stale port-forwards first, so repeat runs are safe.

### Local iteration with `sol dev run`

Once the cluster is up and you have a workspace (see Part 2), use `sol dev run` for rapid code-change iteration:

```bash
sol dev run
```

`sol dev run` discovers every service in `app/<domain>/<name>/` that has a `Dockerfile`, runs a single `dune build` across all of them, then spawns each compiled binary as a **native process** — no Docker image rebuild required. Each service's stdout and stderr are prefixed with `[domain/name]` so you can follow multiple services in one terminal. Ctrl-C cleanly kills all child processes.

The environment variables your services expect are inherited directly from the shell (set by `sol dev up`'s port-forwards):

| Variable | Value (set by `sol dev up`) |
|---|---|
| `KAFKA_BROKERS` | `localhost:9092` |
| `SCHEMA_REGISTRY_URL` | `http://localhost:8081` |
| `POSTGRES_URL` | `postgresql://postgres:dev@localhost:5432/dev` |
| `LOKI_URL` | `http://localhost:3100` |

**When to use `sol dev run` vs `sol up`:**

| | `sol dev run` | `sol up` |
|---|---|---|
| How services run | Native OCaml binaries | Docker containers in k3d |
| On code change | `dune build` + re-run (~seconds) | `docker build` + redeploy (~minutes) |
| Uses k3d infra | Yes (via port-forwards from `sol dev up`) | Yes |
| Good for | Fast edit-compile-run loop | Final smoke test before CI |

Both commands talk to the same Kafka broker, PostgreSQL, and Loki instance that `sol dev up` started. The difference is only in how the service processes themselves are launched.

---

## Part 2 — Scaffold a workspace

A **workspace** is a directory that contains one or more domain teams, each with their own services. Teams communicate through typed Kafka events — never through shared code.

```bash
sol new workspace pluto
cd pluto
```

> **Vendor link:** `sol new workspace` creates `vendor/framework` as a symlink into the Sol source tree. This link is how the generated workspace finds Sol's library source at build time — `dune build` will fail with "Library not found: sol_svc" if it is missing.
>
> When using the **release tarball** (the install path above), the framework source is bundled inside the extracted directory. `sol new workspace` finds it automatically — no `SOL_HOME` needed.
>
> When using a **source checkout**, set `SOL_HOME` before running `sol new workspace`:
>
> ```bash
> export SOL_HOME=~/sol   # set once in ~/.bashrc or ~/.zshrc
> ```
>
> The CLI uses `SOL_HOME` to locate the framework and create the vendor symlinks automatically.

This generates 28 files. Here is what was created and why:

```
pluto/
  dune-project                    ← root dune project (required)
  .ocamlformat                    ← OCaml formatter config
  .dockerignore                   ← excludes _build/ and .git/ from Docker build context
  README.md                       ← workspace-level docs

  sol/prod/aws/us-east-1.yml      ← placeholder deploy target — rename to your real target

  .github/workflows/
    deploy.yml                    ← CI deploy workflow
    sol-ci.yml                    ← Full Sol CI pipeline

  events/payments/
    charged.ml                    ← the Charged event contract
    dune
    sol.toml                      ← declares the Kafka topic name for auto-provisioning

  app/payments/charge_svc/
    lib/handler.ml                ← HTTP route handlers
    lib/dune
    bin/main.ml                   ← service entrypoint
    bin/dune
    Dockerfile
    sol.toml

  app/comms/notify_worker/
    lib/notify_worker.ml          ← Kafka message handler
    lib/dune
    bin/main.ml                   ← worker entrypoint
    bin/dune
    Dockerfile
    sol.toml

  lib/
    notification.ml               ← shared DB module (used by svc and worker)
    dune                          ← pluto_storage library

  db/migrations/
    0001_notifications.sql        ← initial schema
    0001_notifications.down.sql   ← companion rollback migration (used by `sol migrate rollback`)

  test/
    test_schemas.ml               ← schema backward-compatibility CI gate
    dune
```

Two domain teams are wired together out of the box:

- **payments team** — owns the `Charged` event and runs `charge_svc`
- **comms team** — runs `notify_worker`, which consumes `Charged` events published by the payments team

### The event contract

`events/payments/charged.ml` defines the Kafka event schema as an OCaml module:

```ocaml
type t = {
  id          : string;
  customer_id : string;
  amount_cents: int;
  currency    : string;
}

let topic  = "pluto-payments-charges"
let schema = {|{"type":"record","name":"Charged",...}|}
```

The `topic` and `schema` fields satisfy the `Kafka_service.MESSAGE` module type. Sol registers the Avro schema with the schema registry at worker startup. A producer cannot publish a message that breaks the registered schema.

### The HTTP service

`app/payments/charge_svc/lib/handler.ml` defines routes:

```ocaml
let routes pool ~publish_charged ~ot = [
  Route.get  "/health"        ~auth:`Public (fun _req -> Response.ok "ok");
  Route.post "/charges"       ~auth:`Public (fun req -> ...);
  Route.get  "/notifications" ~auth:`Public (fun _req -> ...);
]
```

`POST /charges` generates a charge ID, publishes a `Charged` event to Kafka, and returns `{"id":"ch_XXXXXX","accepted":true}`. `GET /notifications` reads the last 20 rows notify-worker wrote back from PostgreSQL.

`~ot` is the observability handle (Part 6 shows how it's constructed) — `/charges` wraps its work in `Obs_eio.with_span ot ?parent:req.trace_ctx "charges" (fun sp -> ...)` so the request gets both a Tempo trace and a correlated Loki log line, matching the upstream trace if the caller sent a `traceparent` header.

Auth is always declared explicitly on each route. There is no implicit auth based on path conventions.

### The worker

`app/comms/notify_worker/lib/notify_worker.ml` is a Kafka consumer:

```ocaml
module Make (Config : sig
  val pool : Db.pool option
  val ot   : Obs_eio.t
end) = struct
  module Message = Charged
  let group_id = "pluto-comms-notify-worker"

  let handle (msg : Message.t) ~trace_ctx:_ =
    Obs_eio.log_standalone Config.ot Obs_eio.Info
      ~fields:[("charge_id", msg.id); ("customer_id", msg.customer_id)]
      "charge event received";
    (match Config.pool with
     | Some pool -> ignore (Notification.insert pool ...)
     | None -> ());
    Ok ()
end
```

`module Message = Charged` tells Sol which Kafka topic and schema this worker consumes. `group_id` is the Kafka consumer group name. `handle` is called once per message with the decoded payload — there's no `ack` to call; Sol commits the offset for you, only after `handle` returns `Ok ()`.

The `Make(Config)` functor pattern lets you inject the database pool and observability handle without module-level mutable state. Sol's worker runtime (`Worker.Make(W).run`) manages the Kafka connection lifecycle, acknowledgement, graceful shutdown, and per-message metrics.

### The shared storage module

`lib/notification.ml` is used by both the svc and the worker. It wraps two caqti queries:

```ocaml
let insert pool ~charge_id ~customer_id ~amount_cents ~currency = ...
let list_recent pool = ...
```

Both return `(_, Storage_error.t) result`. No exceptions cross module boundaries.

The `lib/dune` file publishes this as `pluto_storage`, a library both services depend on.

---

## Part 3 — Deploy to the local cluster

```bash
sol up
```

For each service that has a `Dockerfile`, Sol:

1. Builds the Docker image and tags it with the short git SHA
2. Pushes it to the local registry (`sol-registry:5000`)
3. Generates Kubernetes manifests (Namespace, Deployment, Service, ServiceAccount, ConfigMap)
4. Validates them against the live API server (`kubectl apply --dry-run=server`)
5. Applies them live

The generated ConfigMap injects cluster-internal service addresses so pods communicate via k8s DNS, not localhost port-forwards:

```
KAFKA_BROKERS       redpanda.redpanda.svc.cluster.local:9093
SCHEMA_REGISTRY_URL http://redpanda.redpanda.svc.cluster.local:8081
LOKI_URL            http://loki.monitoring.svc.cluster.local:3100
TEMPO_URL           http://tempo.monitoring.svc.cluster.local:4318
```

Secrets such as `POSTGRES_URL` and `SOL_API_KEY` are emitted through a
Kubernetes Secret instead of the ConfigMap.

When a service needs a synchronous call to another service, declare it in the
caller:

```toml
[service]
calls = ["checkout/checkout_svc"]
```

Sol injects `CHECKOUT_SVC_URL` and opens only that pair's NetworkPolicy path.
Prefer events for cross-domain flows unless the synchronous dependency is part
of the service contract.

These names are deterministic from the Helm release names and workspace/domain
names chosen by `sol dev up`.

After `sol up` finishes, check what's running:

```bash
sol status
```

```
Namespace: pluto-comms
NAME                              READY   STATUS    RESTARTS   AGE
notify-worker-77859bbfff-77vm6    1/1     Running   0          2m

Namespace: pluto-payments
NAME                           READY   STATUS    RESTARTS   AGE
charge-svc-5464d77bd4-2lnb9    1/1     Running   0          2m
  →  http://localhost:8080  (charge-svc)
```

---

## Part 4 — Run database migrations

```bash
sol migrate
```

If `POSTGRES_URL` is not set, Sol detects the cluster postgres automatically and starts a background port-forward:

```
Forwarding postgresql (cluster) → localhost:15432 ...
Applying migrations from db/migrations...
Done.
```

The migration runner applies SQL files in numeric order and records each applied version in a `sol_<workspace>_schema_migrations` table (for example, `sol_pluto_schema_migrations` when your workspace directory is `pluto`). Re-running `sol migrate` is safe — already-applied versions are skipped.

The table name is derived from your workspace directory name. Use `--table <name>` to override the default if you need a custom tracking table.

Check migration status at any time:

```bash
sol migrate status
```

```
VER     NAME                            APPLIED AT
------------------------------------------------------------
1       0001_notifications              2026-06-05T12:34:56Z
```

---

## Part 5 — Try the API

`sol up` started the port-forward automatically — the service is already reachable at http://localhost:8080. If the port-forward was stopped, run `sol up` again to restart it (or run `kubectl port-forward svc/charge-svc -n pluto-payments 8080:80` directly).

```bash
# Health check
curl localhost:8080/health
# ok

# Create a charge
curl -X POST localhost:8080/charges \
  -H 'Content-Type: application/json' \
  -d '{"customer_id":"cus_123","amount_cents":4999,"currency":"usd"}'
# {"id":"ch_042381","accepted":true}

# List stored notifications
curl localhost:8080/notifications
# [{"charge_id":"ch_042381","customer_id":"cus_123","amount_cents":4999,"currency":"usd"}]
```

---

## Part 6 — Observe logs, metrics, traces, and alerts

Open Grafana at `http://localhost:3000` (admin / dev).

### Logs

Go to **Explore → Loki** and query:

```
{service=~"pluto-.*"} | logfmt
```

You will see structured log lines from both services. Each line includes `level`, `msg`, `span`, `trace_id`, and any fields the handler added. W3C `traceparent` headers propagate across the Kafka boundary, so a charge request's `trace_id` appears in both the `charge-svc` logs and the `notify-worker` logs when the event is consumed.

### Metrics

Go to **Explore → Prometheus** and query:

```
sol_svc_requests_total
sol_worker_messages_total
sol_svc_request_duration_seconds_bucket
```

Sol registers these metrics automatically when `?ot` is wired in the service entrypoint. No instrumentation code is needed in the handler.

### Traces

Unlike metrics, tracing isn't automatic — a handler opts in by wrapping its work in `Obs_eio.with_span`, as `POST /charges` does (Part 2). `sol dev up` provisions Tempo and wires `TEMPO_URL` in automatically, so any handler that calls `with_span` gets a real trace with no extra setup. Click a `charge-svc` log line in the Loki view above: next to `trace_id=...` Grafana shows a **Tempo** button (a derived-field link, no copy-pasting IDs) that jumps straight to that request's span waterfall in **Explore → Tempo**.

Tracing is `-svc`-only for now. `notify-worker` receives the same trace context and logs the matching `trace_id` for correlation, but doesn't wrap its work in a span, so it doesn't emit its own spans to Tempo yet.

### Alerting

Sol ships two starter Prometheus alert rules by default, scoped to the same `workspace`/`domain`/`service` labels as everything above — no extra instrumentation needed:

| Alert | Fires when |
|---|---|
| `SolHighErrorRate` | A service's 5xx rate exceeds 5% of requests, sustained 5 minutes |
| `SolPodRestartLoop` | A pod's container restarts more than 3 times in 15 minutes |

View rule state at `http://localhost:9090/alerts` (`kubectl port-forward -n monitoring svc/prometheus-server 9090:80` if not already forwarded) — each rule shows `inactive`, `pending`, or `firing`. Once a rule fires it also shows up in Alertmanager's own UI (`kubectl port-forward -n monitoring svc/prometheus-alertmanager 9093:9093`, then `http://localhost:9093`).

Alertmanager ships with a `null` receiver by default — alerts fire and are visible in its UI/API, but nothing pages or texts anyone until you point it at a real receiver (Slack, PagerDuty, email). See [`docs/deployment/observability-backends.md`](../deployment/observability-backends.md) for how to wire one up, and to add your own alert rules.

---

## Part 7 — Extend the workspace

Adding a new domain or service follows the same pattern.

### New event type

```bash
sol new event billing/payment_confirmed
```

Generates `events/billing/payment_confirmed.ml` with a stub `type t` and `schema`. Edit the type to match your payload; the compiler will find every place that needs updating.

**Schema backward compatibility:** Changing the `schema` field (the JSON Schema string) may break consumers that are still running against the old schema. The OCaml compiler catches structural type mismatches, but JSON schema changes are only caught at runtime when the worker calls `Kafka_service.register`. To catch breaking schema changes in CI before deploy, run the generated schema compatibility test:

```bash
SCHEMA_REGISTRY_URL=http://localhost:8081 dune test test/
```

`test/test_schemas.ml` (generated by `sol new workspace`) calls `Kafka_service.Schema.check_all` against the schema registry. If the new schema is incompatible with the already-registered version, the test fails and the schema change is blocked before it reaches staging. If `SCHEMA_REGISTRY_URL` is not set, the test skips safely — it is a no-op in unit CI.

### New worker

```bash
sol new worker logistics/fulfillment
```

Generates a minimal worker in `app/logistics/fulfillment_worker/`. Wire the event library into its `dune` file, set `module Message = Payment_confirmed`, implement `handle`, then redeploy:

```bash
sol up
```

### New service

```bash
sol new svc ops/admin
```

Generates `app/ops/admin_svc/` with a stub handler. Add routes and redeploy.

### New scheduled function

```bash
sol new fn billing/invoice
```

Generates `app/billing/invoice_fn/` with a `schedule` field (default `"0 * * * *"`) and a `run` function. Sol reads the schedule literal from source and generates a Kubernetes `CronJob`.

---

## How observability wiring works

Every service entrypoint follows the same pattern, through `Sol_obs` — the
app-facing observability facade (`framework/sol-obs`). Here is the
charge-svc `bin/main.ml`:

```ocaml
Eio_main.run @@ fun env ->
let obs =
  Sol_obs.of_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock
    ~service:"pluto-charge-svc" ~context:[("team", "payments")] ()
in
```

`Sol_obs.of_env` reads `LOKI_URL`/`TEMPO_URL` from the environment, composes
whichever backends are configured (Prometheus is always included), and
applies `~context` as ambient labels (`team = payments`) that appear on
every log line, metric, and trace from this handle — without passing them
explicitly to every call. Handlers use `Sol_obs.log_info`/`log_warn`/
`with_span` instead of calling `Obs_eio` directly; `Sol_obs.obs_eio obs`
and `Sol_obs.metrics_renderer obs` hand the lower-level pieces to
`Service.run`'s `?ot`/`?metrics_renderer`.

When `LOKI_URL`/`TEMPO_URL` are absent (local `dune exec` dev), logs go to
stdout in logfmt format and no traces are emitted. In the cluster,
`sol dev up` sets Loki/Tempo automatically. The code is identical either way.
Workers follow the same pattern, but only service handlers currently opt into
application spans.

---

## CLI reference

```
sol new workspace <name>                          scaffold a new workspace
sol new svc <domain>/<name>                       add an HTTP service
sol new worker <domain>/<name>                    add a Kafka consumer
sol new fn <domain>/<name>                        add a scheduled function
sol new event <team>/<name>                       add a typed Kafka event

sol dev up                                        provision local k3d cluster
sol dev down                                      tear down the cluster
sol dev status                                    show running infra endpoints
sol dev run                                       run services as native processes (fast iteration)

sol plan TARGET                                   print merged app/resource/service plan
sol up [path] [--dry-run] [--tag]                 build images and deploy to local cluster
sol deploy TARGET [--image-tag TAG] [--registry URL]  deploy pre-built images (CI mode)
sol deploy TARGET --emit-to DIR [--image-tag TAG] ...  write YAML for Argo CD (GitOps mode)
sol status [domain]                               show running pods and port-forward hints

sol migrate [apply]                               apply pending migrations
sol migrate status                                show per-file applied/pending table
sol migrate rollback                              roll back the last applied migration

sol rollback [domain/service]                     roll back last deploy for one or all services
sol logs <service> [--no-follow] [--tail=N]       stream logs from a deployed service
sol open logs [SCOPE] [--links]                   open Grafana Explore logs (browser unless --links)
sol open metrics [SCOPE] [--links]                open Grafana metrics dashboard
sol open dashboard [SCOPE] [--links]              open Grafana workspace/service dashboard
#   SCOPE: omit for workspace, domain, domain/service, or resource/<type>/<name>
#   also accepts --observability-backend {local|self_hosted_durable|external},
#   --base-domain DOMAIN, and TARGET

sol secret set <KEY> --env <ENV> --value <VAL> [PATH]   create or update a secret
sol secret list --env <ENV> [PATH]                      list secret keys (values never printed)
sol secret delete <KEY> --env <ENV> [PATH]              delete a secret

# PATH scopes the command to one domain/service (e.g. `payments` or
# `payments/charge-svc`) instead of every domain in the workspace --
# useful when a domain hasn't been deployed yet and has no namespace.

sol cloud plan TARGET                             preview cloud infrastructure changes
sol cloud apply TARGET                            apply cloud infrastructure changes
sol cloud destroy TARGET [--plan|--apply]         destroy cloud infrastructure via Terraform
```

---

## Part 8 — Production deployment

The `sol deploy` command is `sol up` without the build step. It is designed to run in CI after images have already been built and pushed to a production registry.

`sol deploy` takes a required `<env>/<provider>/<region>` target — same convention as `sol plan` — and the target file it resolves must exist first, even if empty. `sol new workspace` scaffolds a placeholder at `sol/prod/aws/us-east-1.yml`; rename it to match your real target if it isn't `prod/aws/us-east-1`.

Set `target.cluster_issuer` in that file to override the cert-manager ClusterIssuer used for service Ingress TLS; it defaults to `letsencrypt-prod`, matching `cli/platform/infra/base`.

### Direct deploy (CI pushes to the cluster)

```bash
# In CI, after docker build && docker push:
sol deploy prod/aws/us-east-1 \
  --image-tag "$GIT_SHA" \
  --registry  "123456789.dkr.ecr.us-east-1.amazonaws.com"
```

Sol generates the same Kubernetes manifests as `sol up` but uses the provided registry and tag for the image reference. The cluster must be reachable (kubeconfig active).

### GitOps deploy (Argo CD watches a manifest repo)

```bash
# In CI:
sol deploy prod/aws/us-east-1 \
  --emit-to   manifests/ \
  --image-tag "$GIT_SHA" \
  --registry  "123456789.dkr.ecr.us-east-1.amazonaws.com"
# → writes manifests/pluto-payments-charge-svc.yaml, manifests/pluto-comms-notify-worker.yaml
# → CI commits and pushes these to the GitOps repo
# → Argo CD detects the change and applies it
```

The generated files contain the full manifest (Namespace, ServiceAccount, ConfigMap, Deployment/Service). If a service enables progressive delivery in `sol.toml`, Sol emits an Argo Rollouts `Rollout` instead of a Kubernetes `Deployment`. Argo CD applies these manifests with `ServerSideApply=true` and prunes resources that are removed.

### Day-2 operations

If a deploy introduces a regression, `sol rollback [domain/service]` rolls back one or all services and waits for the previous revision to become healthy — no kubectl knowledge required.

For services using a standard `Deployment` (no `[infra.rollout]` in `sol.toml`), this calls `kubectl rollout undo deployment/<name>`. For services configured with `[infra.rollout]` (Argo Rollouts), `sol rollback` automatically calls `kubectl argo rollouts undo <name>` instead. This requires the [Argo Rollouts kubectl plugin](https://argoproj.github.io/argo-rollouts/installation/#kubectl-plugin); if the plugin is not installed, `sol rollback` prints the manual command and exits 1.

To inspect what a running service is doing, `sol logs <service>` streams live output directly from the cluster pod, following Sol's namespace convention automatically.

### Progressive delivery with Argo Rollouts

Services can opt into a typed high-level rollout strategy:

```toml
[infra.rollout]
strategy = "canary"
steps = [{weight = 10}, {pause = {duration = 300}}, {weight = 50}, {pause = {}}, {weight = 100}]
```

Canary steps are weight percentages from 0 to 100. For blue-green deployments, use:

```toml
[infra.rollout]
strategy = "blue-green"
```

Blue-green emits active and preview `Service` resources and disables automatic promotion. This is not a raw Argo YAML escape hatch: Sol supports only the fields above, and arbitrary Argo Rollouts features such as analysis templates and traffic-manager integrations are deferred.

See `cli/platform/infra/ci/` for complete GitHub Actions workflow examples for both modes.

### Provisioning a production cluster

Use `sol cloud plan` and `sol cloud apply` to provision production infrastructure. These commands run Terraform against the modules bundled in `cli/platform/infra/` and print the provisioned endpoints on completion.

**AWS (EKS, ECR, RDS, Route53):**

```bash
sol cloud plan prod/aws/us-east-1
sol cloud apply prod/aws/us-east-1
```

**GCP (GKE Autopilot, Artifact Registry, Cloud SQL):**

```bash
sol cloud plan prod/gcp/us-central1
sol cloud apply prod/gcp/us-central1
```

**Plan (show terraform plan without creating resources):**

```bash
sol cloud plan prod/aws/us-east-1
sol cloud plan prod/gcp/us-central1
```

**Pass a Terraform variables file:**

```bash
sol cloud apply prod/aws/us-east-1 --var-file prod.tfvars
```

**Pass one-off Terraform variables:**

```bash
sol cloud apply prod/aws/us-east-1 --var cluster_name=acme-prod --var db_password=...
```

On success the command prints the key provisioned endpoints, then runs `kubeconfig_command` automatically so `kubectl` (and therefore `sol status`/`sol deploy`/`sol migrate`) can reach the new cluster right away — no separate manual step needed:

```
  cluster_name                  acme-prod
  cluster_endpoint              https://ABCDEF123456.gr7.us-east-1.eks.amazonaws.com
  kubeconfig_command            aws eks update-kubeconfig --region us-east-1 --name acme-prod
  ecr_registry                  123456789.dkr.ecr.us-east-1.amazonaws.com

Configuring kubectl...
  kubectl configured -- sol status/deploy/migrate can reach this cluster now.
```

If kubectl auto-configuration fails (no local `aws`/`gcloud` CLI, no network reach, etc.), the command prints the `kubeconfig_command` line above as a warning with the fix — run it yourself before continuing.

Sensitive outputs (database passwords, connection strings) are never printed; retrieve them with `terraform output -raw <name>` if needed.

**Prerequisites:** `terraform` CLI in PATH, and cloud credentials in the environment (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` for AWS; `GOOGLE_APPLICATION_CREDENTIALS` or `gcloud auth application-default login` for GCP).

**Install platform components** (Argo CD, Redpanda, Loki, Prometheus, cert-manager):

```bash
cd cli/platform/infra/base
terraform init
terraform apply \
  -var="base_domain=acme.com" \
  -var="letsencrypt_email=ops@acme.com" \
  -var="install_postgresql=false"   # using RDS or Cloud SQL
```

After `terraform apply`, the cluster is identical to `sol dev up` — same DNS names, same ConfigMap values, same Grafana dashboards.

> **Advanced / manual override:** `sol cloud plan/apply` is a thin wrapper around Terraform. Engineers who need full Terraform control — custom variables, targeted applies, remote state configuration, or workspace management — can invoke Terraform directly against the same modules:
>
> ```bash
> # AWS example
> cd cli/platform/infra/aws
> terraform init
> terraform apply \
>   -var="cluster_name=acme-prod" \
>   -var="base_domain=acme.com" \
>   -var="db_password=<secret>"
> aws eks update-kubeconfig --region us-east-1 --name acme-prod
>
> # GCP example
> cd cli/platform/infra/gcp
> terraform init
> terraform apply \
>   -var="project_id=my-project" \
>   -var="cluster_name=acme-prod" \
>   -var="base_domain=acme.com" \
>   -var="db_password=<secret>"
> gcloud container clusters get-credentials acme-prod --region us-central1
> ```

**Set up Argo CD GitOps** (one-time per cluster):

```bash
# Edit cli/platform/infra/argocd/application.yaml — set GITOPS_REPO_URL and WORKSPACE_NAME
kubectl apply -f cli/platform/infra/argocd/application.yaml
```

From this point, every `git push` to `main` in CI runs `sol deploy --emit-to`, commits the YAML to the GitOps repo, and Argo CD reconciles the cluster automatically.
