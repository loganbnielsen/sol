# Self-Hosted Substrate Contract

Sol deploys your application to Kubernetes. This document defines the minimum
contract a self-hosted environment must satisfy for `sol deploy` to work, and
draws the boundary between what Sol generates and what cloud tooling (Terraform,
Pulumi, cloud console) must provide.

This covers the environment *around* your containers. See
[`runtime.md`](runtime.md) for the other
direction: what the code *inside* a container must actually do, and which of
that Sol's tooling checks versus merely assumes.

## The Boundary

Sol generates **application-layer Kubernetes objects**: namespaces, service
accounts, Deployments, Services, CronJobs, Ingress objects, and NetworkPolicies.
Sol does not provision cloud infrastructure. VPCs, IAM roles, managed databases,
managed Kafka clusters, DNS zones, container registries, and TLS certificates
are all **substrate** — they must exist before `sol deploy` runs.

This boundary is intentional. Terraform, Pulumi, and cloud-native tooling are
already excellent at provisioning substrate. Sol does not attempt to replicate
them. Instead, Sol consumes what they produce.

---

## What You Bring

The following substrate inputs must exist before running `sol deploy`.

### Kubernetes Cluster and Context

- A reachable Kubernetes cluster (k3d locally, EKS, GKE, or any CNCF-conformant
  cluster in production).
- A kubeconfig context that can reach the cluster (`kubectl cluster-info` must
  succeed).
- Cluster admin or a namespace-scoped role with permission to create
  Deployments, Services, CronJobs, Ingress, ServiceAccounts, ConfigMaps,
  Secrets, and NetworkPolicies.

### Container Registry Prefix

- A registry that the cluster's nodes can pull from.
- Pass the prefix via `sol deploy <env>/<provider>/<region> --registry <prefix>`,
  or set it as the target file's own `registry` (used as the default when
  `--registry` is omitted).
  Example: `123456789.dkr.ecr.us-east-1.amazonaws.com`
- The cluster must have image-pull credentials configured (imagePullSecret,
  IRSA, or workload identity). Sol does not create pull credentials.

### Kafka Brokers and Schema Registry

- Comma-separated broker addresses, e.g. `broker-1:9092,broker-2:9092`.
- A Confluent-compatible schema registry URL, e.g. `http://schema-registry:8081`.
- Sol workers and services read `KAFKA_BROKERS`, `SCHEMA_REGISTRY_URL` and the
  required `KAFKA_SECURITY_PROTOCOL` (plus `KAFKA_SSL_*`/`KAFKA_SASL_*` when used) from
  their environment. The generated ConfigMap points at Sol's in-cluster
  Redpanda defaults, including `KAFKA_SECURITY_PROTOCOL=plaintext`. For an external Kafka substrate, override those values via
  `[infra.env] config = { ... }` in each service's `sol.toml` or through a
  GitOps overlay.
- Sol's workspace scan discovers topic intent from `events/**/sol.toml`, but
  it does not create an external Kafka cluster for you.

### Postgres Connection Secret

- A Kubernetes Secret containing a `POSTGRES_URL` key with a valid libpq
  connection string, e.g.
  `postgresql://user:password@host:5432/dbname?sslmode=require`.
- Sol renders a per-workload Secret named `<service>-secrets` and injects it
  through `envFrom`. In live direct deploys, `POSTGRES_URL` must be present in
  the caller's environment. In GitOps output, the value is emitted empty or via
  an `ExternalSecret`, depending on `--secret-backend`.
- Sol does not create the database in the application deploy path, run
  migrations at cluster startup, or manage credentials rotation. Use
  `sol migrate` to apply migrations after `POSTGRES_URL` is available.
- The contract key is **`POSTGRES_URL`**, not `DATABASE_URL`. There are no
  `postgres_secret_name`, `kafka_secret_name`, or `tls_secret_name` fields in
  `sol.toml`; per-workload Secret names are derived as `<service>-secrets`, and
  `sol.toml` declares only secret *keys* under `[infra.env] secrets`.

### Observability Endpoints

- **Loki**: HTTP push URL, e.g. `http://loki.monitoring.svc:3100`.
  The generated ConfigMap defaults `LOKI_URL` to Sol's in-cluster Loki service.
- **Prometheus Pushgateway**: HTTP URL for `sol fn` metrics push, e.g.
  `http://pushgateway.monitoring.svc:9091`.
  The generated ConfigMap defaults `PUSHGATEWAY_URL` to Sol's in-cluster
  Pushgateway service.
- **Tempo**: OTLP/HTTP URL, defaulted as `TEMPO_URL` when Tempo is installed.
- Override these with `[infra.env] config = { ... }` if you use external
  observability endpoints.
- There are no `loki_url` or `pushgateway_url` fields in `sol.toml`. These are
  ConfigMap values (`LOKI_URL`, `PUSHGATEWAY_URL`, `TEMPO_URL`) with Sol
  defaults, overridden through `[infra.env] config` rather than a dedicated
  `sol.toml` key.

### Base Domain and TLS (Optional)

- A DNS name under which services are exposed, e.g. `myapp.example.com`.
  Set `ingress_host` in `[infra.deploy]` of each service's `sol.toml` to
  enable host-specific TLS for that service.
- When `ingress_host` is set, Sol generates an Ingress object for the `-svc`
  with a host rule, a per-service TLS secret, and cert-manager annotations.
  Override the ClusterIssuer with `target.cluster_issuer`; it defaults to
  `letsencrypt-prod`, matching `platform/cloud/modules/platform`.
- If a service has no `ingress_host`, Sol still generates an Ingress, but gives
  it a per-service dev host, `<k8s-name>.<namespace>.localhost`, and leaves TLS
  and HTTPS redirect off. The namespace is part of the host so several services
  — and several workspaces sharing one cluster — never collide.
- **No DNS record is created for you.** `platform/cloud/modules/platform` installs
  ingress-nginx, and `platform/cloud/aws/cluster` can create the Route53 zone, but
  Sol does not run external-dns: an `ingress_host` only resolves once its
  record exists. Find the controller's address with
  `kubectl get svc -n ingress-nginx ingress-nginx-controller` (the
  `EXTERNAL-IP`) and create an `A`/alias or `CNAME` record for each
  `ingress_host` in that zone (`route53_zone_id` / `route53_nameservers` are
  `platform/cloud/aws/cluster` outputs; on GCP use the Cloud DNS zone). A wildcard
  record such as `*.acme.com` covers every service in one entry.
- Locally, `sol local infra up` installs the same ingress-nginx chart (NodePort) and
  forwards the controller to `http://localhost:8088`. Reach a service there
  with its dev host as the `Host` header, e.g.
  `curl -H 'Host: charge-svc.acme-payments.localhost' http://localhost:8088/health`
  — browsers resolve `*.localhost` to loopback, so on many systems the host
  works in the URL directly. No DNS or TLS is involved.

---

## What Sol Generates

Running `sol deploy` (or `sol up` locally) produces the following Kubernetes
objects for each service in your workspace:

| Object | When generated |
|---|---|
| Namespace | Always. One namespace per `<workspace>-<domain>` pair. |
| ServiceAccount | Always. One per service, in its namespace. |
| ConfigMap | Always. Contains Sol's platform defaults plus any `[infra.env] config` keys from `sol.toml`. |
| Secret | Always. Direct deploy reads required secret values such as `POSTGRES_URL` from the caller's environment. GitOps mode (`--emit-to`) emits empty `stringData` placeholders or `ExternalSecret` resources, depending on `--secret-backend`. |
| Deployment | For every `-svc` and `-worker`. |
| Service (ClusterIP) | For every `-svc`. |
| CronJob | For every `-fn`, using the `schedule:` field from `sol.toml`. |
| Ingress | For every `-svc`; TLS and HTTPS redirect only when `ingress_host` is set in `sol.toml`. |
| NetworkPolicy | Always. Denies NodePort egress, enforces non-root containers. |

Sol's artifact is the set of YAML manifests. In direct mode (`sol deploy`
without `--emit-to`) Sol applies them via `kubectl apply`. In GitOps mode
(`sol deploy --emit-to <dir>`) Sol writes them to a directory for Argo CD or
Flux to apply.

**Secret values in GitOps output:** In GitOps mode, all `kind: Secret` resources
are emitted with empty `stringData` values. A comment block above `stringData`
lists every key that must be populated before the manifest is applied:

```yaml
kind: Secret
# Populate these values before applying.
# Use `sol secret set <KEY> --env <env>` or your secrets manager.
stringData:
  POSTGRES_URL: ""
```

Use `sol secret set` to write values directly to the cluster, or replace the
empty strings with references from Sealed Secrets, External Secrets Operator,
or equivalent. Do not commit manifest files that contain real secret values.

No per-service manifest hand-editing is required or expected. If a generated
manifest does not fit your needs, open an issue or add a `sol.toml` escape
hatch rather than editing generated YAML.

---

## What Sol Does Not Generate

Sol deliberately does not provision:

- **VPCs, subnets, security groups, firewall rules** — use Terraform, Pulumi,
  or your cloud console.
- **IAM roles, service accounts (cloud), OIDC providers** — use your cloud
  provider's IAM tooling or the Terraform modules in `platform/cloud/aws/cluster/` and
  `platform/cloud/gcp/cluster/` as a starting point.
- **Managed databases (RDS, Cloud SQL)** — use cloud-native managed services or
  the Terraform modules in `platform/cloud/modules/platform/`.
- **Managed Kafka clusters (MSK, Confluent Cloud, Redpanda Cloud)** — use the
  managed service directly. Point `KAFKA_BROKERS` at the bootstrap endpoint.
- **DNS zones, A/CNAME records** — use Route 53, Cloud DNS, or your DNS
  registrar.
- **TLS certificates** — use cert-manager, ACM, or your cloud provider's
  certificate service.
- **Container registries (ECR, GCR, Docker Hub)** — create the registry once
  via Terraform or the cloud console and pass the prefix to Sol.
- **Cloud accounts, billing, quota increases** — out of scope.

---

## Setup Options

### k3d (Local Development)

`sol local infra up` automates the full local substrate:

```
sol local infra up
```

This command starts a k3d cluster, a local registry container at
`localhost:5000` (cluster-internal: `sol-registry:5000`), Redpanda (Kafka),
Loki, Prometheus, and Grafana via Helm. No manual substrate setup required for
local development.

### Terraform Modules (Provided as a Starting Point)

The `platform/cloud/` directory contains Terraform modules that provision typical
production substrate:

| Path | What it creates |
|---|---|
| `platform/cloud/modules/platform/` | Generic Kubernetes substrate: namespaces, RBAC, cert-manager, ingress-nginx |
| `platform/cloud/aws/cluster/` | AWS: VPC, EKS cluster, ECR registry, RDS PostgreSQL, IAM OIDC |
| `platform/cloud/gcp/cluster/` | GCP: GKE Autopilot, Artifact Registry, Cloud SQL, Workload Identity |
| `platform/cloud/delivery/argocd/` | Argo CD `Application` manifest for GitOps mode |
| `platform/cloud/delivery/ci/` | GitHub Actions workflows for direct and GitOps CI modes |

These modules are **starting points**. They express Sol's opinion about a
minimal, secure substrate. Modify them freely to match your organization's
standards. Sol does not require these specific modules — any substrate that
satisfies the contract above works.

### Pulumi / CloudFormation / Other IaC

Bring your own. As long as the substrate contract is satisfied (cluster
reachable, registry accessible, secrets exist), `sol deploy` works regardless
of how the substrate was provisioned.

### Manual Cloud Console (Advanced)

Possible, but not recommended for production. The substrate contract does not
mandate IaC — it mandates that the listed resources exist and are reachable.

---

## Deployment Flow

A typical `sol deploy` invocation in CI:

```bash
# 1. Build and push images (CI build job — not Sol's responsibility)
docker build -t $REGISTRY/orders-svc:$SHA .
docker push $REGISTRY/orders-svc:$SHA

# 2. Deploy — Sol's responsibility
sol deploy prod/aws/us-east-1 \
  --registry   $REGISTRY \
  --image-tag  $SHA
```

What Sol does in step 2:

1. Discovers services in `app/` (any directory with a `Dockerfile`).
2. Reads `sol.toml` for service metadata (domain, primitive type, schedule,
   secret names, config keys, `ingress_host`).
3. Resolves the registry — explicit `--registry`, falling back to the
   target file's `registry` — and fails before any build/apply step if
   neither is set. There is no hardcoded local-registry fallback: `sol
   deploy` is always the customer-cluster path.
4. Renders namespaces, service accounts, Deployments/Services/CronJobs,
   Ingress (when `ingress_host` is set in `sol.toml`), and NetworkPolicies.
5. Applies manifests via `kubectl apply` (direct mode) or writes the per-service
   YAML files plus the release artifact (`sol-release-<id>` record and
   `sol-current-release` pointer) to the `--emit-to` directory (GitOps mode), so
   the release metadata travels with the bundle.

Sol does not SSH into nodes, modify cloud resources, or touch anything outside
the Kubernetes API server.

### GitOps Mode

```bash
sol deploy prod/aws/us-east-1 \
  --registry   $REGISTRY \
  --image-tag  $SHA \
  --emit-to    ./gitops/manifests
```

Manifests are written to `gitops/manifests/`. Commit and push. Argo CD or Flux
detects the change and applies it to the cluster. Sol's role ends when the files
are written.

Alongside the manifests, Sol writes `sol-release-<id>.yaml` (named by the plan's
content-addressed release id — the same id every workload carries as its
`release` label) and a `sol-current-release.yaml` pointer. Both are pure
functions of the released content, so re-deploying identical content leaves the
bundle byte-identical and the diff empty. The emitted record is marked
`apply_mode: gitops`: a controller, not Sol, owns those resources, so
`sol rollback` refuses a GitOps-owned release instead of direct-applying against
the controller (see the rollback section of the pipeline doc).

Invocation provenance is *not* in the bundle: `sol up` and `sol deploy` record a
separate immutable `sol-deployment-<deployment_id>` ConfigMap in the target's
cluster (minted id, the release attempted, timestamp, commit, dirty, actor,
target, outcome), listed by `sol deployments`. One event per deploy *attempt*,
success or failure; the release record is written only on success. Keeping
provenance out of the release artifact is what lets two deploys of identical
content share one release record and one empty GitOps diff while still being two
auditable attempts.

### Production Profile

A target claims a production contract only by selecting one, on its environment
or on the target itself in `sol/environments.yml`. An environment named `prod`
claims nothing.

```yaml
# sol/environments.yml
pilot:
  profile: production-single-region
  targets:
    aws/us-east-1:
```

`profile` is accepted on an environment or a target, never in `sol.yml`: `sol.yml`'s
`target:` section is inherited by every target, so a profile there is rejected
rather than opting every environment in.

A target that selects `production-single-region` goes through a preflight on
every `sol deploy` (including `--dry-run`) before any cluster call, lease or
emitted file. The preflight checks each guarantee the profile requires for the
workloads being deployed and refuses if any is unmet. Each unmet guarantee is
named along with who must act: the application, the target, or Sol itself.
There is no "accepted but unverified" outcome: the profile is unsatisfiable
until Sol can establish every guarantee it requires.

Every guarantee now has a real establishment branch — none is staged
(`not_yet_established` no longer exists). Preflight establishes only what is
observable offline: a declaration, a rendered configuration, or a
profile-derived setting. It never claims live behaviour; the failure and
recovery behaviour behind the numeric DEC-026 bounds is HARDEN-002's evidence.

| Guarantee | Required when |
|---|---|
| Qualified provider/substrate (AWS) | always |
| Qualified version set | always |
| Direct apply reconciliation authority | always — `--emit-to` is refused |
| Recoverable remote infrastructure state | always |
| Scoped operator identity | always |
| Alert delivery to an owner | always |
| Immutable artifact identity | always — every workload deploys by `--image-ref <service>=<repo>@sha256:<digest>` |
| Workload credential posture | always |
| Workload availability | any service or worker |
| Postgres durability | migrations or a `postgres` resource |
| Kafka durability | topics declared in `events/` `sol.toml`, or a `kafka` resource |

Only declared dependencies make a guarantee applicable. A worker's shape
implies nothing: it may consume Kafka or host `sol-jobs`. A worker that
consumes Kafka without a declared topic or `kafka` resource is not detected
yet, so declare every Kafka dependency.

The workload credential posture is a Sol-owned renderer property: every workload
gets no mounted service-account token, and runtime credentials rotate by
`sol secret set` followed by a verified restart. See
[`credential-rotation.md`](credential-rotation.md).

Recoverable state and scoped identities are target declarations: a locked,
versioned, encrypted remote state backend (`state_bucket`/`state_lock_table`,
which Sol provisions by default via `platform/cloud/aws/bootstrap`) and the named
provisioning/deploy/operator role ARNs plus a restricted public-endpoint CIDR.
See [`production-bootstrap.md`](production-bootstrap.md) for the exact commands
and recovery procedure.

The availability guarantee is a declared semantic, not a replica count: a
workload states `single` (the default) or `node-failure-tolerant` in its
`sol.toml`, and a target declares the fixed `node_failure_headroom_nodes` that
makes restoration possible. Sol refuses a claim the workload cannot satisfy
(functions, volume-backed workloads, fewer than two replicas) before render and
fails the preflight when the headroom is missing. See
[`workload-availability.md`](workload-availability.md).

Migration ordering is enforced live: a production deploy verifies that every
migration in the workspace's `db/migrations` is present in the authoritative
`schema_migrations` table (read-only, via a short-lived in-cluster Job) after the
static preflight and before any workload mutation, failing closed when the check
cannot be performed. `--dry-run`/`--emit-to` create nothing and report the
prerequisite as not verified. See
[`migration-ordering.md`](migration-ordering.md).

The artifact guarantee is satisfied by how the application deploys:
`sol deploy --image-ref <service>=<repo>@sha256:<digest>` pins each workload to
immutable bytes, and the preflight rejects a mutable tag. A bare
`--image-ref <repo>@sha256:<digest>` is accepted when the scope selects exactly
one service. Each reference is checked against its registry before anything is
applied, and the resolved digest is what the release record — and therefore a
later rollback — uses, so a moved tag cannot change what a recorded release
runs.

The qualified version set is a declared framework language per workload.
Declare `language: ocaml` (or `typescript`) in the service's `sol.yml` entry;
the profile's initial compatibility matrix qualifies OCaml only, so a
TypeScript workload fails preflight with that reason. The exact supported CLI,
language, Kubernetes, provider-module and chart versions are published in
[`compatibility.md`](compatibility.md).

The Postgres and Kafka durability guarantees have a written operator
procedure — backup, restore, failover and integrity verification — in
[`application-data-recovery.md`](application-data-recovery.md). Qualification
evidence for those procedures belongs to HARDEN-002; the runbook is the
procedure, not proof a target passed.

A deploy that passes preflight carries `production-single-region/v1` in its plan
(`--emit-plan-to`, with the guarantees as `evidence_requirements`) and in its
deployment event. The claim is never written into the release record: a release
is content, and two targets may deploy the same release while only one of them
claims the profile.

---

## Summary

| Layer | Owner |
|---|---|
| Cloud accounts, billing | You |
| VPC, subnets, firewall | You (Terraform / cloud console) |
| IAM, workload identity | You (Terraform / cloud console) |
| Kubernetes cluster | You (Terraform / cloud console / managed service) |
| Container registry | You (Terraform / cloud console) |
| Managed Kafka, Postgres | You (Terraform / cloud console / managed service) |
| DNS, TLS certificates | You (Terraform / cert-manager / cloud console) |
| Kubernetes Secrets (values) | You (sealed-secrets, External Secrets Operator, etc.) |
| Application manifests | **Sol** (`sol deploy`) |
| Local dev substrate | **Sol** (`sol local infra up`) |
