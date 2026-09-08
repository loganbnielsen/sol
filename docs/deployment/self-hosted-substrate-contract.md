# Self-Hosted Substrate Contract

Sol deploys your application to Kubernetes. This document defines the minimum
contract a self-hosted environment must satisfy for `sol deploy` to work, and
draws the boundary between what Sol generates and what cloud tooling (Terraform,
Pulumi, cloud console) must provide.

This covers the environment *around* your containers. See
[`service-runtime-contract.md`](service-runtime-contract.md) for the other
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
- Sol workers and services read `KAFKA_BROKERS` and `SCHEMA_REGISTRY_URL` from
  their environment. You supply these values via a Kubernetes Secret whose name
  you pass as `kafka_secret_name` in `sol.toml`.
- Sol generates the Secret reference in the Deployment env block. It does not
  create the Kafka cluster or seed topics.

### Postgres Connection Secret

- A Kubernetes Secret containing a `DATABASE_URL` key with a valid libpq
  connection string, e.g.
  `postgresql://user:password@host:5432/dbname?sslmode=require`.
- Pass the Secret name via `postgres_secret_name` in `sol.toml` or the
  `--postgres-secret` flag.
- Sol generates a `valueFrom.secretKeyRef` reference. It does not create the
  database, run migrations at cluster startup, or manage credentials rotation.
  Use `sol migrate` to apply migrations from CI after the schema Secret exists.

### Observability Endpoints

- **Loki**: HTTP push URL, e.g. `http://loki.monitoring.svc:3100`.
  Pass via `LOKI_URL` environment variable or `loki_url` in `sol.toml`.
- **Prometheus Pushgateway**: HTTP URL for `sol fn` metrics push, e.g.
  `http://pushgateway.monitoring.svc:9091`.
  Pass via `PUSHGATEWAY_URL` or `pushgateway_url` in `sol.toml`.
- Both are optional. If omitted, the corresponding observability features are
  disabled at runtime without crashing the service.

### Base Domain and TLS (Optional)

- A DNS name under which services are exposed, e.g. `myapp.example.com`.
  Set `ingress_host` in `[infra.deploy]` of each service's `sol.toml` to
  enable Ingress generation for that service.
- When `ingress_host` is set, Sol generates an Ingress object for the `-svc`
  with a host rule matching that value.
- TLS termination is the cluster's responsibility. Sol does not create
  `Certificate` resources or interact with cert-manager unless you add a
  `tls_secret_name` field to the service spec in `sol.toml`. Sol will then
  reference that secret in the Ingress TLS block, but it will not provision the
  certificate.
- If no service has `ingress_host` set, no Ingress objects are generated and
  services are only reachable via `kubectl port-forward` or ClusterIP.

---

## What Sol Generates

Running `sol deploy` (or `sol up` locally) produces the following Kubernetes
objects for each service in your workspace:

| Object | When generated |
|---|---|
| Namespace | Always. One namespace per `<workspace>-<domain>` pair. |
| ServiceAccount | Always. One per service, in its namespace. |
| ConfigMap | When `config:` keys are present in `sol.toml`. |
| Secret (redacted) | Always, in GitOps mode (`--emit-to`). All `stringData` values are empty strings with a comment listing the keys to populate. In direct mode the dev defaults are used. |
| Deployment | For every `-svc` and `-worker`. |
| Service (ClusterIP) | For every `-svc`. |
| CronJob | For every `-fn`, using the `schedule:` field from `sol.toml`. |
| Ingress | For `-svc` when `ingress_host` is set in `sol.toml`. |
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
  provider's IAM tooling or the Terraform modules in `platform/infra/aws/` and
  `platform/infra/gcp/` as a starting point.
- **Managed databases (RDS, Cloud SQL)** — use cloud-native managed services or
  the Terraform modules in `platform/infra/base/`.
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

`sol dev up` automates the full local substrate:

```
sol dev up
```

This command starts a k3d cluster, a local registry container at
`localhost:5000` (cluster-internal: `sol-registry:5000`), Redpanda (Kafka),
Loki, Prometheus, and Grafana via Helm. No manual substrate setup required for
local development.

### Terraform Modules (Provided as a Starting Point)

The `platform/infra/` directory contains Terraform modules that provision typical
production substrate:

| Path | What it creates |
|---|---|
| `platform/infra/base/` | Generic Kubernetes substrate: namespaces, RBAC, cert-manager, ingress-nginx |
| `platform/infra/aws/` | AWS: VPC, EKS cluster, ECR registry, RDS PostgreSQL, IAM OIDC |
| `platform/infra/gcp/` | GCP: GKE Autopilot, Artifact Registry, Cloud SQL, Workload Identity |
| `platform/infra/argocd/` | Argo CD `Application` manifest for GitOps mode |
| `platform/infra/ci/` | GitHub Actions workflows for direct and GitOps CI modes |

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
5. Applies manifests via `kubectl apply` (direct mode) or writes YAML files
   to the `--emit-to` directory (GitOps mode).

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
| Local dev substrate | **Sol** (`sol dev up`) |
