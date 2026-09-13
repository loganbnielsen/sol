# Sol — Roadmap

> Current planning focus: the live/dev deploy path is tracked in
> `docs/planning/LIVE_DEV_DEPLOY_ROADMAP.md`. This file keeps the broader
> historical roadmap and product direction.

## Vision

Sol is not a web framework, a Kafka wrapper, a Kubernetes deployment tool, or a
CLI wrapper around DevOps scripts.

Sol is an open-source OCaml software factory for backend systems. The factory
turns direct-style OCaml domain code into running production services by owning
the repeatable machinery around it: scaffolding, build conventions,
containerization, deployment-plan synthesis, Kubernetes/GitOps output,
observability wiring, release inspection, and rollback.

The framework pieces exist to make the intended architecture the path of least
resistance:

- Teams own domains
- Domains communicate through typed events, never shared code
- Infrastructure is derived from code structure, not written by hand
- Operational concerns are standardized across every service
- A small engineering organization can run production systems without dedicated platform engineers

Sol productizes the repeatable parts of platform engineering and DevOps. It
removes the need to know Terraform, Helm, Kubernetes, image wiring, or CI deploy
glue to ship a production service. It does not remove the need to make sound
engineering decisions.

Every roadmap item should strengthen one of these goals. A feature that increases flexibility but weakens architectural consistency is usually the wrong tradeoff.

---

## Current Status

| Layer | Status |
|---|---|
| Kafka (core, producer, consumer, service) | Complete |
| Observability core (`obs-eio` — tracing, logging, metrics API) | Complete |
| Observability backends (Loki, Prometheus) | Complete |
| HTTP service layer (`-svc`) | Complete |
| Function layer (`-fn`, cron) | Complete |
| Worker layer (`-worker`, Kafka consumer) | Complete |
| Observability auto-wiring (`-svc`, `-fn`, `-worker`) | Complete |
| Observability app facade (`framework/sol-obs` — `Sol_obs.t`) | Complete — scaffold templates and app handler examples use it instead of composing Loki/Prometheus/Tempo providers directly |
| Storage (PostgreSQL) | Complete |
| Sol CLI — scaffold (`sol new workspace/svc/worker/fn/event`) | Complete |
| Sol CLI — local infra (`sol dev up/down/status/run`) | Complete |
| Sol CLI — deploy (`sol up`, `sol status`, `sol migrate`) | Complete |
| Sol CLI — secrets (`sol secret set/list/delete`) | Complete |
| Production deployment pipeline (`sol deploy`, Terraform, Argo CD) | Complete |
| Progressive delivery (`[infra.rollout]`, Argo Rollouts) | Complete |
| Cloud infrastructure (`sol cloud plan/apply/destroy`) | Provisions AWS EKS+ECR or GCP GKE+Artifact Registry via Terraform — experimental, live plan tested against AWS |
| AWS application-level integration (`aws-eio`: credentials + SigV4 + HTTP transport) | Complete — proven against a live AWS endpoint |
| AWS S3 client (`s3-eio`) | Extracted to a [standalone package](https://github.com/loganbnielsen/s3-eio) — v1 scope (put/get/delete/head_object) built and live-tested against a real bucket (put/head/get/delete round trip + the 404 path) |
| AWS DynamoDB client (`dynamodb-eio`) | Extracted to a [standalone package](https://github.com/loganbnielsen/dynamodb-eio) — v1 scope (Client + typed Index/Entity layer) built and live-tested against a real table (put/get/delete round trip + the missing-key path, plus CAS/create-iff-missing); newer `Remove`/`Add`/`Delete`/`And`/`Or`/`Not_equals` update-op coverage added but not yet run live |
| AWS Lambda integration (`lambda-eio`) | Extracted to a [standalone package](https://github.com/loganbnielsen/lambda-eio) — protocol proven at three levels: local mock server, AWS's Runtime Interface Emulator, and a real deployed Lambda function (`examples/echo-lambda/test-e2e.sh` — builds, pushes to ECR, deploys, invokes twice for real, tears down with independently-confirmed teardown). `sol-fn`'s `FN.trigger` variant (`Cron`/`Lambda`) wired in |

---

Sol is built in layers, each one making the factory more complete. The Kafka
layer is the proof-of-concept. Each subsequent phase adds machinery that a team
would otherwise have to build, wire, document, and operate themselves.

---

## ~~Dogfood Alpha~~ ✓ done — 2026-06-11

Sol proved the self-hosted/open-source factory end-to-end. A new user can install Sol,
create a workspace, run it locally, and deploy it into customer-owned
infrastructure without learning OCaml internals, Kubernetes object shapes, Helm
chart wiring, or Terraform module structure.

**Completed:** DOGFOOD-001 through DOGFOOD-005, plus DOGFOOD-008 (Kafka
external listener), DOGFOOD-009 (Loki 2.x compatibility). See `pipeline/dogfood/`
for full reports.

### What the dogfood found

**All core flows passed:**
- `sol new workspace` → `dune build` → `sol dev up` → `sol up` → `sol status` → `sol rollback`
- `sol migrate` auto-detects cluster postgres via port-forward
- `sol logs`, `sol secret set/list/delete` all functional
- `sol deploy --dry-run / --emit-plan-to / --emit-to` all functional
- Loki logs from in-cluster workers are complete (trace/span IDs in logfmt line body)
- Kafka external advertised listener correctly configured for `sol dev run` path

**Follow-up tickets (captured, not blockers):**

| Finding | Source | Priority |
|---------|--------|----------|
| `sol logs` shows only stdout; Loki-routed logs require Grafana | DOGFOOD-003/004 | Low |
| `sol up` with fixed `dev` tag doesn't restart pods on code change | DOGFOOD-004 | Low |
| `sol rollback <path>` uses different path format from `sol up` | DOGFOOD-004 | Low |
| Deployment plan omits Kafka topics and pending migrations | DOGFOOD-005 | Medium |
| GitOps YAML includes secrets in plain-text `stringData` | DOGFOOD-005 | High |
| `--emit-plan-to` always executes; needs `--dry-run` to preview only | DOGFOOD-005 | Low |

### Factory Ownership Lanes

Sol has one app model and three current ownership lanes. A future hosted lane
should run the same factory contract rather than introduce a second product
shape.

| Lane | Who owns infra? | User interface | Sol responsibility |
|---|---|---|---|
| Local Dev | Developer machine | `sol dev up`, `sol dev run`, `sol up` | Provision local substrate, run app, expose logs/metrics |
| Managed Customer Cloud | Customer cloud account, Sol substrate shape | high-level env/provider/tier config | Provision/update Sol's standard substrate, deploy app, operate release workflow |
| Exported Self-Managed | Customer | generated Terraform/manifests/GitOps artifacts | Generate artifacts and inspect releases; customer owns apply/drift/ops |
| Future Sol Hosted | Sol | hosted UI/API plus CLI | Run the factory floor: builders, previews, deploys, secrets, observability, release history, RBAC, audit, billing |

> **Implementation note:** A mock Sol-hosted executor was spiked in Phase 7 and
> removed on 2026-06-22 because the open-source factory contract was not yet
> stable enough to support a managed control plane. That removal was an
> implementation reset, not a rejection of hosted Sol as a future commercial
> factory floor.

The overlap is the app model and deployment plan, not shared Terraform editing.
If a user edits generated Terraform, they have moved from managed customer-cloud
to exported self-managed mode.

### Product Boundary

Users describe the app:

- services, workers, functions
- events and topics
- migrations
- secrets and environment names
- domain/URL intent
- rollout preference
- region/tier at product level

Sol decides the default infrastructure shape:

- Kubernetes resource shapes
- service discovery and env wiring
- registry and image naming
- ingress/TLS wiring
- secret references
- logs/metrics labels
- release metadata
- rollout/rollback mechanics

`cli/platform/infra/` is therefore not the primary user interface. It is an
implementation of the substrate contract for customer-cloud and exported
self-managed lanes, and should also inform Sol's future hosted substrate.

### Dogfood Alpha Acceptance Test

The Dogfood Alpha milestone is complete when a fresh environment can run:

```bash
sol new workspace acme
cd acme
sol dev up
sol dev run
sol up
sol status
sol logs
sol secret set DATABASE_URL --env local --value ...
sol migrate
sol deploy dev/aws/us-east-1 --dry-run  # requires sol/dev/aws/us-east-1.yml with a registry set
sol rollback
```

and the same workspace has a documented path to customer-owned infrastructure
without requiring the user to hand-author Kubernetes manifests or Terraform.

Hosted work is deferred until this path is boring enough that Sol Cloud can be
described as "Sol runs the same factory for you."

---

## ~~Immediate — Kafka Layer Hardening~~ ✓ done

### ~~Schema CI enforcement~~ ✓ done
### ~~Fix silent message drop in consume~~ ✓ done
### ~~Consumer integration e2e~~ ✓ done

FFI boundary fix is in (`caml_release_runtime_system` / `caml_acquire_runtime_system`
around all blocking C calls). All 26 Kafka tests pass against a live Redpanda broker.

---

## ~~Now — Observability Backends~~ ✓ done

The `obs-eio` core API is built and tested (18/18 unit tests). The `backend` record
type (`emit_span`, `emit_metric`) is the integration point for all concrete backends.
Backends are push-based and work from any process (`-worker`, `-svc`, `-fn`) — no HTTP
server layer required.

### ~~obs-eio-loki~~ ✓ done

Logfmt lines pushed to Loki's HTTP push API with W3C `trace_id` / `span_id` as Loki 3.x
structured metadata (indexed, filterable, separate from log line text). 8/8 tests pass
including two live round-trip tests against real Loki.

**Key design choices made:**
- Log lines use **logfmt** format (`level=info msg=... span=... key=val`) — readable inline,
  parseable with `| logfmt` in LogQL
- `trace_id` / `span_id` go in **Loki structured metadata** (third value-tuple element),
  not embedded in the line — keeps them indexed and clickable in Grafana Explore
- Stream labels: `service` always + whitelisted `label_names` from `Obs_eio.t` context
- Unreachable Loki logs to stderr, never raises

**Local infrastructure:** `cli/platform/local/scripts/ensure-loki.sh` + `ensure-grafana.sh`
(Grafana pre-wired with Loki datasource at `http://localhost:3000`)

### ~~obs-eio-prometheus~~ ✓ done

Prometheus metrics exposed via in-process state, scrapeable at a configurable endpoint
or pushable to Pushgateway.

**Package:** `obs-prometheus-eio` (extracted to `~/Code/obs-prometheus-eio`, 2026-08-25;
lived at `integrations/observability/obs-eio-prometheus/` at the time this phase shipped)
**Deliverables:**
- `Obs_prometheus.create : unit -> Obs_eio.backend * (unit -> string)` — backend + renderer ✓
- Counter/gauge/histogram families with correct Prometheus text exposition format ✓
- 10/10 unit tests pass — counter accumulation, gauge last-write-wins, histogram bucket
  sorting, label escaping, concurrent emit safety ✓
- `push` deferred to Phase 2 (`-fn`) — spec now in `~/Code/obs-prometheus-eio` ✓

**Key design choices:**
- `Mutex` (not `Eio.Mutex`) protects the registry — safe across Eio domains, no switch needed
- `emit_span` is a no-op — spans go to Loki
- Default histogram buckets: `[0.005; 0.01; 0.025; 0.05; 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0]`
- Renderer snapshots under the lock then formats without holding it
- `metric_event` carries `help` string (added to obs-eio core) so backends can emit `# HELP` lines

---

## Backlog — Kafka Layer

The Kafka layer is otherwise functionally complete. Remaining gaps before production-ready:

### Schema CI enforcement (historical)

**The problem:** Schema compatibility is enforced at service startup when `Kafka_service.register` is called. A developer can commit a breaking schema change and only discover it when the pod restarts in staging or production.

**The fix:** Extract schema checking into a standalone `Kafka_service.Schema.check` function that takes only a `net` handle and a `MESSAGE` module — no producer, no broker. The convention in a Sol workspace: every `-worker` that owns a topic has a `test/test_schemas.ml` that calls this for each of its `MESSAGE` modules. These run as part of `dune test` with only the schema registry up.

```
make schema-check  →  ensure registry running, dune test **/test_schemas*
```

**Deliverables:**
- `Kafka_service.Schema.check : net -> (module MESSAGE) -> (unit, string) result`
- `Kafka_service.Schema.check_all : net -> (module MESSAGE) list -> (unit, string) result`
- Convention doc: where `test_schemas.ml` lives and what it contains
- Makefile target

### Fix silent message drop in consume

**The problem:** In `Kafka_service.consume`, decode errors are `eprintf`'d and returned as `Ok ()`. Bad messages disappear with no record and no way to retry.

**The fix:** Surface decode errors to the caller. The handler should receive a typed result so it can decide whether to skip, retry, or dead-letter the message.

---

## ~~Phase 1 — HTTP Service Layer (`-svc`)~~ ✓ done

Adds the REST service primitive. A `-svc` is a long-running HTTP server that handles requests, wired into the Sol observability and deployment stack.

**Module type:**

```ocaml
module type HANDLER = sig
  val routes : Sol.Route.t list
end
```

**Route definition:**

```ocaml
let routes = [
  Sol.Route.post "/payments/charge"          ~auth:(`Jwt ["write:payments"]) handle_charge;
  Sol.Route.post "/payments/internal/charge" ~auth:`Api_key                  handle_internal_charge;
  Sol.Route.get  "/health"                   ~auth:`Public                   handle_health;
]
```

Auth is always declared explicitly on each route. Sol does not infer auth strategy from path conventions. The `/payments/internal/` convention is a human-readable signal, not a framework trigger.

**Auth strategies:**
- `` `Public `` — no auth, open to the internet
- `` `Api_key `` — internal service-to-service, validated against a key from k8s secrets
- `` `Jwt of string list `` — public-facing, JWT bearer token with required scopes

**Entrypoint:** `Sol.Service.Make(H)` functor — takes your `HANDLER` module and produces a runnable HTTP server with health check, metrics endpoint, and graceful shutdown wired in.

**Deliverables:** ✓ all complete
- `Auth` — `` `Public ``, `` `Api_key `` (env/file), `` `Jwt of jwt_config `` with v1 unsafe guard ✓
- `Route` — `get/post/put/patch/delete` constructors, `:name` param capture, trailing-slash distinction ✓
- `Request` / `Response` — typed record API with `param_exn`, `query_param`, `header` helpers ✓
- `Service.HANDLER` + `Service.Make` functor — cohttp-eio 6.2.1 backend, `?stop` graceful shutdown, drain timeout ✓
- Built-in `/healthz` + `/metrics` (configurable auth) ✓
- 32/32 tests: routing, auth, service integration ✓

**Package:** `framework/sol-svc/`

---

## ~~Now — Phase 2 — Function Layer (`-fn`)~~ ✓ done

Adds the function primitive. In v1, functions are triggered exclusively by cron schedules and deployed as Kubernetes CronJobs. The abstraction is the function — the trigger is configuration.

The schedule is not the defining characteristic of a `-fn`. The defining characteristic is `val run : unit -> (unit, string) result`: a unit of business logic that executes and exits. Future trigger modes (Kafka topic, HTTP path, event bridge) would add entries to `sol.toml` without touching the `FN` module type or the `run` implementation.

**Module type:**

```ocaml
module type FN = sig
  val schedule : string                         (* cron expression — v1 trigger *)
  val run : unit -> (unit, string) result
end
```

**Entrypoint:** `Sol.Fn.Make(F)` functor — produces an executable that runs `F.run ()` once and exits. Sol generates the k8s `CronJob` manifest from the schedule and container image.

**Deliverables:**
- `Sol.Fn.FN` module type
- `Sol.Fn.Make` functor
- k8s `CronJob` manifest generation from `schedule`
- Wire `Obs_prometheus.push` here — `-fn` processes are ephemeral so Prometheus cannot
  scrape them; `Sol.Fn.Make` should call `push` at the end of `F.run ()` before exit.
  The `push` implementation lives in `obs-prometheus-eio` (now `~/Code/obs-prometheus-eio`)
  and is already specced but intentionally deferred to this phase.

---

## ~~Phase 3 — Observability~~ ✓ done (auto-metrics for `-svc` and `-fn`)

Adds structured logging and metrics to all three primitives (`-svc`, `-worker`, `-fn`) with zero instrumentation code required beyond initialization.

**Logging:** Structured JSON to stdout, ingested by Loki via the k8s log collector. Log lines include service name, domain, trace ID, and any fields the developer adds. No log configuration required — Sol's `Make` functors wire this on startup.

**Metrics:** Prometheus metrics exposed at `/metrics` automatically. Sol provides baseline metrics for all primitives:
- `-svc`: request count, latency histogram, error rate per route
- `-worker`: messages consumed, processing latency, error rate, consumer lag
- `-fn`: invocation count, duration, last run status

**Dashboards:** Grafana dashboard templates for each primitive, deployable as k8s `ConfigMap` resources via Helm or Argo CD.

**Deliverables:**
- ~~Auto-wiring in `Sol.Service.Make`~~ ✓ `sol_svc_requests_total{method,route,status_class}` + `sol_svc_request_duration_seconds{method,route}`; pass `?ot:Obs_eio.t` to wire in
- ~~Auto-wiring in `Sol.Fn.Make`~~ ✓ `sol_fn_invocations_total{status}` + `sol_fn_duration_seconds` (done in Phase 2)
- ~~`Sol.Worker.Make`~~ ✓ `sol_worker_messages_total{status}` + `sol_worker_message_duration_seconds`; pass `?ot:Obs_eio.t` to wire in
- `Sol.Log` / `Sol.Metrics` — convenience wrappers; deferred to Phase 5 CLI (just use `Obs_eio.register_counter/histogram` directly for now)
- Grafana dashboard templates — deferred to Phase 6 (k8s deploy layer)
- Loki + Prometheus + Grafana k8s manifests — deferred to Phase 6

---

## ~~Phase 4 — Storage (PostgreSQL)~~ ✓ done

Adds a PostgreSQL integration aligned with Sol's error model and Eio concurrency. PostgreSQL is Sol's opinionated default storage layer — not an abstracted interface over multiple backends. The choice is deliberate: `caqti` provides first-class Postgres support with Eio-compatible async drivers; local dev is `docker run postgres` with no AWS credentials or emulators required; and the cloud-agnostic deployment story (AWS EKS, GCP GKE) is preserved.

All operations return `(_, Sol.Storage.error) result`. No exceptions at public API boundaries.

**Migrations are a first-class deliverable.** Sol ships with a built-in migration runner — ordered SQL files applied at startup or via `sol migrate`. Developers do not reach for an external tool to add a column.

**Key design decisions:**
- No generic repository abstraction over multiple backends — Sol is opinionated, Postgres is the answer, not a pluggable option
- `caqti` + `caqti-driver-postgresql` as the Eio-compatible driver layer
- `Sol.Storage.Table.Make(Schema)` functor produces a typed table client where the compiler enforces column types and query shape
- Connection pool managed by the `Make` functor; callers never touch raw connections
- Migrations live in `db/migrations/` as numbered SQL files (`0001_init.sql`, `0002_add_index.sql`); Sol applies them in order and tracks applied versions in a `sol_schema_migrations` table (library default); the `sol migrate` CLI uses a workspace-prefixed default `sol_<workspace>_schema_migrations`, overridable with `--table`
- Local dev: `docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=dev postgres:16`

**Deliverables:**
- `Sol.Storage.Postgres` — `get`, `insert`, `update`, `delete`, `query`, `transaction`
- `Sol.Storage.Table.Make(Schema)` functor for typed table access
- `Sol.Storage.Migration` — migration runner (`apply`, `status`, `rollback`)
- `sol migrate` CLI command (wired in Phase 5)
- `cli/platform/local/scripts/ensure-postgres.sh` for local dev
- Unit tests against a real Postgres instance; gated on `POSTGRES_URL` env var (same pattern as Kafka and Loki integration tests)

---

## Phase 5 — CLI and Scaffolding

The `sol` CLI is the developer-facing entry point to the framework. Its job is to make Sol's opinions the path of least resistance — not just scaffold files, but get a developer from zero to a real running cluster in minutes.

**Acceptance test:** A developer who has never seen the codebase should be able to run the following and have services running in a real cluster in ten minutes:

```bash
sol new workspace acme
cd acme
sol dev up              # provision local k3d cluster + deploy infra into it
sol up                  # build images, synthesize manifests, deploy services
sol status              # show running pods and endpoints
```

---

### Implementation

**Package:** `cli/sol/` — binary at `_build/default/cli/sol/bin/main.exe`

**Stack:** `cmdliner` 2.x for argument parsing. Templates are OCaml string literals embedded directly in the binary — no external template files, no runtime file resolution. Self-contained and relocatable.

**Local cluster:** k3d v5.6.0 + Helm v3.21.0. k3d chosen over minikube: starts in ~10s, works on WSL2 without a hypervisor, includes a built-in image registry that `sol up` pushes to directly.

---

### ~~Step 1~~ ✓ — `sol new workspace/svc/worker/fn/event`

All five scaffold commands fully implemented and verified. `sol new workspace acme` generates 17 files that pass `dune build` on the first shot with no manual edits. See `docs/planning/WORK_SUMMARY.md` §16 for the full scaffold contract.

---

### ~~Step 2~~ ✓ — `sol dev up/down/status`

Implemented in `cli/sol/bin/cmd_local.ml`. k3d cluster lifecycle, Helm chart installs (Redpanda, PostgreSQL, Loki, kube-prometheus-stack), port-forward manager (PID files in `.sol/`), endpoint summary table.

**Testing status:** k3d v5.6.0 and Helm v3.21.0 are now installed. End-to-end test pending (Step 2a below).

---

### ~~Step 7~~ ✓ — `sol migrate`

Implemented in `cli/sol/bin/cmd_migrate.ml`. Thin Eio + caqti wrapper over `Sol.Storage.Migration`. Verified end-to-end against live postgres. See `docs/planning/WORK_SUMMARY.md` §16.

---

### ~~Step 2a~~ ✓ — Validate `sol dev up` end-to-end

Validated against a live cluster. Two issues found and fixed during the run:

1. **Redpanda `resources.cpu.cores=1` rejected** — Helm parsed `1` as `int64`; chart expects `float64` or string. Fixed: pass `1.5`.
2. **Redpanda requires cert-manager CRDs** for TLS. Fixed: `--set tls.enabled=false` for dev.
3. **Service name corrections** — actual names from `kubectl get svc`: `loki` (not `loki-stack`), `loki-grafana` (not `loki-stack-grafana`).
4. **Prometheus chart** — using `prometheus-community/prometheus` (lighter) instead of `kube-prometheus-stack`. Pushgateway included.
5. **WSL2 k3d** — no special flags needed; cluster creation worked cleanly.

All five endpoints verified: kafka `localhost:9092`, postgres `localhost:5432`, loki `localhost:3100`, grafana `localhost:3000`, pushgateway `localhost:9091`.

---

### ~~Step 3~~ ✓ — `sol up`

Builds Docker images for all services in the workspace, generates k8s manifests, validates them, and deploys to the cluster.

```bash
sol up                                    # build + deploy all services
sol up --scope payments/charge_svc        # build + deploy one unit
sol up --dry-run                          # print YAML to stdout, do not apply
```

#### v1 design (template-based, validated)

`sol up` v1 uses embedded YAML string templates rather than the full typed `Sol_cli.Manifest` AST. This is not a throwaway: the templates define the exact manifest shape that the typed AST will produce in Phase 6. Templates are validated against the live API server with `kubectl apply --dry-run=server` before any live apply, keeping them disciplined.

The typed `Sol_cli.Manifest` AST and `sol.toml` merge logic are deferred to Phase 6, when the CI integration requires programmatic manipulation of the manifest graph.

#### Service discovery

`sol up` scans `app/<domain>/<name>/` and infers the primitive type from the directory suffix:

| Suffix | k8s resources generated |
|--------|------------------------|
| `_svc` | `Namespace` + `Deployment` + `Service` (NodePort) + `ServiceAccount` + `ConfigMap` |
| `_worker` | `Namespace` + `Deployment` + `ServiceAccount` + `ConfigMap` |
| `_fn` | `Namespace` + `CronJob` + `ServiceAccount` + `ConfigMap` |

Schedule for `_fn` is read from the `FN.schedule` value in `lib/<name>_fn.ml` via regex — no TOML parser needed.

#### Naming conventions (locked)

| Concern | Convention |
|---------|-----------|
| Namespace | `<workspace>-<domain>` (e.g. `acme-payments`, `acme-comms`) |
| Image name | `localhost:5000/<workspace>/<name>:<git-sha>` |
| Image tag | Short git SHA from `git rev-parse --short HEAD`; overridable with `--tag` |
| Workspace name | Top-level directory name (e.g. `acme` if run from `acme/`) |

#### In-cluster env vars (critical, verified against live cluster)

Pods communicate via k8s service DNS, not host port-forwards. The generated `ConfigMap` injects cluster-internal addresses. These are exact service names verified by `kubectl get svc` against a running `sol dev up` cluster:

```
KAFKA_BROKERS       = redpanda.redpanda.svc.cluster.local:9093
SCHEMA_REGISTRY_URL = http://redpanda.redpanda.svc.cluster.local:8081
POSTGRES_URL        = postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev
LOKI_URL            = http://loki.monitoring.svc.cluster.local:3100
PUSHGATEWAY_URL     = http://prometheus-prometheus-pushgateway.monitoring.svc.cluster.local:9091
TEMPO_URL           = http://tempo.monitoring.svc.cluster.local:4318
```

Host port-forward mapping (for local `dune exec` dev against the same cluster):

```
localhost:9092   → redpanda:9093     (kafka)
localhost:8081   → redpanda:8081     (schema registry)
localhost:5432   → postgresql:5432   (postgres)
localhost:3100   → loki:3100         (loki)
localhost:3000   → grafana:80        (grafana)
localhost:9091   → prometheus-prometheus-pushgateway:9091
localhost:4318   → tempo:4318        (tempo, OTLP/HTTP ingestion)
localhost:3200   → tempo:3200        (tempo, query API)
```

These addresses are deterministic from the Helm release names in `sol dev up`. Hardcoded in v1 — no dynamic discovery needed.

**Helm release names** (set by `sol dev up`, determines all DNS names above):

| Component | Release name | Namespace |
|-----------|-------------|-----------|
| Kafka | `redpanda` | `redpanda` |
| PostgreSQL | `postgresql` | `postgresql` |
| Loki | `loki` | `monitoring` |
| Grafana | `grafana` | `monitoring` |
| Alloy (log shipping, OBS-039) | `alloy` | `monitoring` |
| Prometheus | `prometheus` | `monitoring` |
| Tempo (tracing, OBS-042; all primitives via `Sol_obs`, FEAT-030) | `tempo` | `monitoring` |

#### `-svc` manifest details

- `Deployment`: 1 replica, image from build step, `containerPort: 8080`
- `livenessProbe`: GET `/healthz` port 8080, `initialDelaySeconds: 5`, `periodSeconds: 10`
- `readinessProbe`: same as liveness
- Resources: `requests: {cpu: 100m, memory: 128Mi}`, `limits: {cpu: 250m, memory: 256Mi}`
- `Service`: type `NodePort`, port 80 → 8080; k3d exposes NodePort on the host automatically

#### `-worker` manifest details

- `Deployment`: 1 replica, no ports, no liveness probe (Kafka poll loop is the health signal)
- Resources: same defaults as `-svc`

#### `-fn` manifest details

- `CronJob`: schedule extracted from source, `restartPolicy: OnFailure`, `backoffLimit: 3`
- Resources: same defaults

#### sol.toml (v1: skipped)

In v1, `sol.toml` files are present (generated by scaffold) but not parsed by `sol up`. All values are defaults. Phase 6 adds the `Sol_cli.Toml` parser and deep-merge into the manifest AST.

#### Pipeline

1. **Discover** — find all `app/<domain>/<name>-{svc,worker,fn}/` dirs with a `Dockerfile`
2. **Build** — `docker build -t localhost:5000/<workspace>/<name>:<sha> <dir>` for each service
3. **Push** — `docker push localhost:5000/<workspace>/<name>:<sha>`
4. **Render** — fill YAML templates with image tag, namespace, env var ConfigMap
5. **Validate** — `kubectl apply -f - --dry-run=server` (halt on any error)
6. **Apply** — `kubectl apply -f -` (live); report created/updated/unchanged per resource

`--dry-run` skips steps 5 and 6 and prints YAML to stdout instead.

---

### ~~Step 4~~ ✓ — `sol status`

Shows what's running. Minimal implementation: `kubectl get pods -A` filtered to the workspace's namespaces, with NodePort endpoints annotated.

```bash
sol status              # all domains in the current workspace
sol status payments     # payments domain only
```

**Output:**
```
NAMESPACE        NAME              STATUS    READY   AGE
acme-payments    charge-svc        Running   1/1     3m
acme-comms       notify-worker     Running   1/1     3m
```

Implementation: parse workspace name from the current directory, derive namespace labels, call `kubectl get pods -n <ns>` for each domain. No dynamic pod-watching needed for v1.

---

### ~~Step 3b~~ ✓ — Logistics/fulfillment extension (acceptance test)

After `sol dev up` + `sol up` are working, validate the full loop against a real multi-domain extension:

1. `sol new event billing/payment_confirmed` — new cross-domain event in venus
2. `sol new worker logistics/fulfillment` — new worker in new domain
3. Wire `billing_events` library dep into worker dune, implement handler
4. `sol up` — build both new images, deploy to cluster
5. Observe logs in Grafana (`{service=~"venus-.*"} | logfmt`), confirm trace spans cross the domain boundary
6. Verify `sol_worker_messages_total` appears in Prometheus for the logistics domain

This is the real acceptance test: a new domain stood up in a running cluster with observability from the first message, without touching a Helm chart or writing a Kubernetes manifest.

---

### Deliverables status

| Deliverable | Status |
|---|---|
| `cli/sol/` package skeleton + `cmdliner` wiring | ✓ done |
| `sol new workspace <name>` — 17-file scaffold, compiles first try | ✓ done |
| `sol new svc/worker/fn/event` | ✓ done |
| `sol dev up/down/status` — k3d + Helm orchestration | ✓ done, validated |
| `sol migrate` / `sol migrate status` | ✓ done, verified |
| `sol up` — template-based v1 with dry-run validation | ✓ done |
| `sol status` | ✓ done |
| `Sol_cli_manifest` — typed k8s manifest rendering shared by `sol up` and `sol deploy` | ✓ done |
| `Sol_cli_toml` — `sol.toml` parser (scale, env, deploy, labels sections) | ✓ done |
| `Sol_cli_deployment_plan` / `Sol_cli_env_target` / `Sol_cli_executor` | ✓ done (Phase 6) |

---

## ~~Phase 6 — Production Deployment Pipeline~~ ✓ done

Phase 5 built the synthesis pipeline and proved it against a local k3d cluster. Phase 6 connected that same pipeline to CI, production cloud clusters, and GitOps tooling.

### What Phase 6 delivered

- `Sol_cli_deployment_plan` — typed deployment plan (workspace, env_config, service_spec, topics, migrations) ✓
- `Sol_cli_env_target` — `Local_k3d`, `Customer_k8s_direct`, `Customer_k8s_gitops`, `Sol_hosted`; `validate` ✓
- `Sol_cli_executor` — `local`, `direct`, `gitops` executors ✓
- `sol deploy --image-tag --dry-run --emit-to` flags ✓
- `sol deploy --emit-plan-to FILE` — plan JSON serialization (experimental schema) ✓
- `sol.toml` parsing — all supported fields are read from real user files ✓
- `cli/platform/infra/aws/` and `cli/platform/infra/gcp/` Terraform modules ✓
- `cli/platform/infra/base/` cluster-agnostic Helm bootstrapping ✓
- Argo CD `Application` manifest + GitOps emit mode ✓
- `docs/deployment/self-hosted-substrate-contract.md` — what Sol generates vs what the user brings ✓
- `docs/deployment/escape-hatches.md` — four-level escape hatch hierarchy ✓

### Deployment modes

**Local (`sol up`)** — builds Docker images and deploys to the local k3d cluster provisioned by `sol dev up`. Intended for development and smoke-testing.

**Customer-cloud direct (`sol deploy`)** — CI builds images, pushes them to a production registry, then `sol deploy <env>/<provider>/<region> --image-tag $SHA --registry $REGISTRY` synthesizes manifests and applies them directly to a customer-managed Kubernetes cluster. The target resolves `sol.yml` + `sol/<env>/<provider>/<region>.yml` for `--registry`'s default and the `env` manifest label — same convention as `sol plan`.

```bash
sol deploy prod/aws/us-east-1 --image-tag <sha>            # deploy with a specific image tag
sol deploy prod/aws/us-east-1 --image-tag <sha> --dry-run  # emit YAML only, for PR diff review
```

**Customer-cloud GitOps (`sol deploy --emit-to`)** — `sol deploy <target> --emit-to <dir>` writes synthesized YAML to a directory instead of applying it. CI pushes that directory to a separate GitOps repo; Argo CD reconciles the cluster. The workspace repo never contains committed manifests.

```bash
sol deploy prod/aws/us-east-1 --emit-to /tmp/manifests --image-tag $SHA --registry $REGISTRY
# → CI pushes /tmp/manifests/* to the GitOps repo
# → Argo CD detects the change and applies it
```

**Sol-hosted executor** — spiked in Phase 7 and subsequently removed
(2026-06-22). The mock implementation was removed so the self-hosted factory
contract could harden first; `sol cloud deploy` and the hosted runtime modules
no longer exist in the codebase. Hosted remains a future product lane that
should reuse the same deployment plan and release inspection model.

### `sol.toml` supported fields

All fields are optional. Anything omitted uses Sol's opinionated default.

```toml
[infra.scale]
replicas = 2
cpu      = "500m"
memory   = "512Mi"

[infra.env]
config = { LOG_LEVEL = "debug" }   # extra ConfigMap entries
secrets = ["DATABASE_URL", "API_TOKEN"]

[infra.deploy]
rollout_strategy = "Recreate"      # or "RollingUpdate" (default)
ingress_host     = "api.example.com"
ingress_path     = "/v1"

[infra.labels]
extra_labels = { team = "payments", cost-center = "billing" }

[infra.rollout]
strategy = "blue-green"            # or "canary" with steps
```

`[infra.rollout]` canary/blue-green and `[infra.env].secrets` are implemented.
`[infra.kafka]` extra topics remain future work.

### `cli/platform/infra/` — Cloud cluster provisioning

Terraform modules for bootstrapping the cluster itself. Run once per environment by the platform team, not on every deploy.

- `cli/platform/infra/aws/` — EKS cluster, VPC, RDS Postgres, ECR, Route53
- `cli/platform/infra/gcp/` — GKE Autopilot cluster, VPC, Cloud SQL, Artifact Registry, Cloud DNS
- `cli/platform/infra/base/` — cluster-agnostic: Argo CD, kube-prometheus-stack, Loki, Redpanda, cert-manager, ingress-nginx

After `terraform apply`, the cluster looks identical to `sol dev up` — same infra components, same Helm charts, same Sol-generated manifests.

---

## ~~Phase 7 — Progressive Delivery, CI Scaffold, Sol-Hosted Executor~~ ✓ done

Phase 7 covered the work remaining after the Phase 6 deployment pipeline.

### ~~Argo Rollouts — progressive delivery (FEAT-011)~~ ✓ done

`sol.toml` `[infra.rollout]` section implemented. `Sol_cli_manifest` synthesizes an Argo
`Rollout` resource instead of a plain `Deployment` when `progressive_delivery` is set.
Canary (weighted steps, pause/auto-promote) and blue-green (active + preview services,
manual promotion) both supported. Teams opt in by adding a few lines to `sol.toml`.

### ~~CI workflow scaffold (FEAT-012)~~ ✓ done

`sol new workspace` now generates `.github/workflows/sol-ci.yml` with build, test,
image build/push, deployment plan export, and GitOps manifest emit steps. Secret
and registry placeholders are explicit.

### ~~Sol-hosted executor spike (FEAT-010)~~ ✓ done → modules removed 2026-06-22

`Sol_cli_hosted_executor` and `Sol_cli_hosted_model` were implemented as a mock
boundary for the hosted path. DEC-001..DEC-007 resolved. The spike was
subsequently removed on 2026-06-22 as part of the self-hosted factory hardening
phase — these modules no longer exist in the codebase.

### ~~Hosted release inspection and diagnostics (FEAT-015)~~ ✓ done

`Sol_cli_release_inspection` defines the Sol-native release inspection surface:
deployment-plan summary, image refs, affected services, rollout status, health
status, error reasons, rendered manifest facts, reconciliation events,
Kubernetes event summaries, and raw failure details.

> Note: `Sol_cli_hosted_executor` references in this section were removed with
> the hosted executor deletion (2026-06-22). `Sol_cli_release_inspection` itself
> is retained.

### ~~Hosted default URLs and custom-domain flow (FEAT-017)~~ ✓ done → removed 2026-06-22

`Sol_cli_hosted_url` (DNS-safe URL generation) was part of this work and has been deleted.

---

## Next — Post-Dogfood Hardening

Addresses the findings surfaced during Dogfood Alpha and turns the tested
self-hosted factory path into a safer production path. See
`docs/planning/POST_DOGFOOD_GAMEPLAN.md` for the bird's-eye plan.

### Priority items

| Item | Priority | Description |
|------|----------|-------------|
| ~~GitOps secrets — replace `stringData` with sealed/external secret refs~~ ✓ done (FEAT-019) | High | `sol deploy --emit-to` now emits redacted `Secret` placeholders by default. Pass `--secret-backend external-secrets --secret-store-ref <name>` to emit `ExternalSecret` CRDs for the External Secrets Operator. |
| Deployment plan completeness | Medium | `--emit-plan-to` JSON shows `"topics": []` and `"migrations": []`. Surface the actual Kafka topics and pending migration state. |
| First release binary (DOGFOOD-007) | Medium | `git tag v0.1.0-alpha.1 && git push origin v0.1.0-alpha.1` + GitHub release with pre-built binaries. |
| ~~`sol logs` Grafana pointer~~ ✓ done (FEAT-023) | Low | `sol logs` now prints a copyable Grafana Explore URL with a pre-built LogQL query before streaming kubectl logs. Pass `--grafana-base-url` to override the default `http://localhost:3000`. |
| Path format unification (`sol rollback`) | Low | `sol rollback` uses `domain/svc`; `sol up` uses `app/domain/svc`. Pick one or document both explicitly. |
| Fixed-tag pod restart | Low | With a fixed `dev` image tag, `sol up` does not restart running pods. Consider forcing a rollout restart when the build SHA changes even if the tag does not. |

### Deploy & runtime visibility — three-layer model (decision, 2026-09-01)

Surfaced by the first live AWS smoke test: Loki is app-push-based
(`obs-loki-eio`), so a pod that never starts (OOMKilled, CrashLoopBackOff,
ImagePullBackOff, unschedulable) never logs anything to Loki — the failures a
user most needs explained are exactly the ones the current pipeline can't
show. Decision: don't build hosted/managed logging infra for users (different
company shape — auth, billing, retention, abuse, uptime). Make the user's own
cluster observable instead, with the right data source per layer:

| Layer | Source | Consumers |
|---|---|---|
| Deploy/build logs | Local command output — `sol deploy`, Docker/buildx, Terraform, Helm | Stored per run under `.sol/runs/<run-id>/`; compact progress printed, full log attached/tailed on failure. Never store deploy diagnostics only inside a cluster that the run itself may tear down. |
| Cluster/deployment diagnosis | `kubectl` — pods, events, image pull errors, OOMKilled, scheduling failures, rollout status | Powers `sol status`, `sol deploy status`, failed-deploy summaries. Most reliable source when the app never starts, so it does not depend on Loki. |
| Runtime logs | Loki — app logs, worker logs, platform pod logs once promtail/an agent scrapes pod stdout (not just app-pushed lines) | `sol logs --scope <domain>/<unit>` prefers Loki, falls back to `kubectl logs` when a Loki *query* fails, not only when Loki is absent. |

**Follow-up work — status corrected 2026-09-11.** This paragraph previously described the work above as "not yet ticketed". Three of the four items had in fact already landed, and the fourth is now ticketed:

- **Kubernetes-derived diagnosis** in `sol status` — done (OBS-001; `Sol_cli_status.service_diagnoses_named` → `Sol_cli_rollout_diagnosis.diagnose_service_live`).
- **Pod-stdout collection** — done, and with **Alloy** rather than promtail: `cli/platform/infra/base/alloy/logs.alloy.tftpl` uses `discovery.kubernetes "pods"` + `loki.source.kubernetes`, so it tails pod logs through the Kubernetes API instead of depending on app-pushed lines.
- **`sol logs` runtime fallback** — done: triggered from `Sol_cli_loki.classify_process_error` (timeout, connection, other) at five call sites.
- **Run IDs and local `.sol/runs/` logging for `sol deploy`** — the one genuine gap. `Sol_cli_run_log` exists, but its only caller is `cmd_cloud_tf.ml` (the terraform phases), so `sol up`/`sol deploy` still keep their diagnostics only in the terminal that ran them. Tracked as **FEAT-055**.

**`sol logs --scope <domain>/<unit>` fallback is a runtime check, not a config flag.** Trigger
the `kubectl logs` fallback on any of: Loki query failure, timeout (~5s),
auth/connect error, or unhealthy Loki pods — not only "Loki not installed".
Print why before falling back (`Loki unavailable: query timed out after 5s.
Falling back to Kubernetes logs for charge-svc...`) so the user isn't left
guessing which source they're looking at. If the target pods aren't running,
include `kubectl describe pod` event excerpts, not just `kubectl logs`.

**`sol status` leads with Kubernetes-derived diagnosis unconditionally**, even
when Loki is healthy — it's the layer that explains a rollout failure when
the app never ran, so it can't be secondary to Loki:

```
charge-svc rollout failed

Pod charge-svc-...: ImagePullBackOff
Reason: failed to pull image ...
Last events:
  FailedPull ...
  BackOff ...
```

Loki stays the richer follow-up path once the platform itself is healthy —
never the only path to debugging why it isn't.
