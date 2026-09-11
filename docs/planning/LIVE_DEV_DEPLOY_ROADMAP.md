# Live/Dev Deploy Roadmap

Goal: make Sol feel like a simple software factory for local dev and live
deploys without hiding cost, state, or rollback risk.

## Current Reality

- `sol dev up` creates the local substrate.
- `sol up` builds every discovered Dockerfile-backed service and applies
  Kubernetes manifests.
- `sol cloud plan/apply` creates customer-cloud substrate with Terraform.
- `sol cloud destroy` tears that substrate down with Terraform.
- `sol deploy` applies pre-built image tags or emits GitOps manifests.
- Changed-service detection is manual today: pass a service path, or all
  services are deployed.
- `-fn` deploys as Kubernetes `CronJob`; Lambda deployment is not wired into
  Sol's deploy path.

## Project 1: Safe Cloud Dogfood

Prove the live AWS path without surprise spend.

Completion criteria:

- `sol cloud plan dev/aws/us-east-1` shows a reviewable plan.
- `sol cloud apply dev/aws/us-east-1` provisions the low-cost dev stack.
- Printed outputs are enough to configure kubectl and registry login.
- Base platform components install successfully on the live cluster:
  ingress-nginx, cert-manager, Redpanda, Loki/Grafana, Prometheus, and
  pushgateway.
- Loki, Prometheus, and Grafana are reachable through either ingress or
  temporary `kubectl port-forward`.
- Read-only checks prove observability is functional:
  Loki responds to `/ready`, Prometheus responds to `/-/ready`, and Grafana
  responds to `/api/health`.
- `sol cloud destroy dev/aws/us-east-1 --plan` previews teardown.
- `sol cloud destroy dev/aws/us-east-1 --apply` completes.
- A read-only AWS CLI verification step confirms EKS, RDS, ECR, and load balancer resources are gone. Before `terraform destroy` runs, any `LoadBalancer`-type Kubernetes Service (e.g. ingress-nginx's) is deleted first — its AWS ELB/NLB isn't tracked by Terraform's own state, so leaving it in place risks an orphaned billed resource or a blocked VPC/subnet deletion (AUDIT-064).
- A dated dogfood report records commands, failures, fixes, and rough cost.

Tests:

- No unit test should hit AWS.
- Terraform adapter argv tests cover init, plan, apply, plan-destroy, destroy.
- Live test uses the smoke-test tfvars and IAM policy only.
- Live observability test uses `kubectl get pods`, short-lived port-forwards,
  and HTTP readiness probes only; it does not require deploying an app service.

## Project 2: Changed-Service Build And Deploy

Deploy only what changed unless the user asks for everything.

Completion criteria:

- `sol build --changed --base <ref>` prints and builds impacted services.
- `sol deploy --changed --base <ref>` deploys only impacted services.
- Changes under shared framework/runtime paths trigger all services.
- Changes under `events/` trigger affected workers, or all workers until topic
  ownership is explicit enough to narrow safely.
- Manual service path filtering keeps working.
- Default `sol up` behavior stays simple and predictable.

Tests:

- Workspace fixture with multiple services.
- Git-diff path classifier tests for service-local, shared, event, docs-only,
  and unknown-path changes.
- Dry-run output proves unchanged services are skipped.

## Project 3: Target Files

Make app topology explicit at the root and deployment placement explicit in
target files whose paths carry env/provider/region.

Target model:

- `sol.yml` is the source of truth for project, services, resources,
  resource-specific shape, and service/resource bindings.
- `sol/<env>/<provider>/<region>.yml` is the deploy target file.
- Target identity is derived from the path, for example
  `prod/aws/us-east-1`; provider and region are not repeated inside the YAML.
- A target file owns its regional instance set. A resource named `app_db` in
  two target files means two physical regional instances of the same logical
  resource.
- Code discovery fills in boring facts like service paths and generated
  service type; it does not guess costly topology.
- Costly decisions stay explicit: provider, regions, clusters, managed
  resources, indexes, backups, and scale.
- Cross-region resource references are reserved as absolute refs:
  `/us-east-1/analytics_db`. They mean same env/provider remote access, not
  replication.
- Cross-env resource sharing is forbidden. Cross-provider references are
  reserved for later and must not work by accident.
- V1 supports local `uses` refs only. Cross-region sharing and replication are
  separate later features.

Target CLI:

```sh
sol plan dev/aws/us-east-1
sol deploy dev/aws/us-east-1

sol cloud plan prod/aws/us-east-1
sol cloud apply prod/aws/us-east-1
sol cloud destroy prod/aws/us-east-1
```

Completion criteria:

- `sol.yml` can define services, resources, and service `uses` bindings.
- DynamoDB resources require declared keys and indexes; they are never inferred
  from code.
- `sol/<env>/<provider>/<region>.yml` can override registry, base domain,
  resource sizing, and service scale.
- `sol plan <env>/<provider>/<region>` prints the merged app/resource/service
  plan before Terraform or kubectl runs.
- `sol cloud plan <env>/<provider>/<region>` resolves provider, region, and
  Terraform variables from the merged Sol config.
- `sol deploy <env>/<provider>/<region> --image-tag <tag>` resolves registry and target
  metadata from the merged Sol config.
- CLI flags still override target file values.
- Missing required target values fail before Terraform or kubectl runs.

Tests:

- Parser tests for valid and invalid `sol.yml` and override files.
- Merge tests for base config plus `sol/<env>/<provider>/<region>.yml`.
- Command request tests for target file plus CLI override precedence.
- Dry-run tests prove resolved regions, resources, indexes, registry, and
  base-domain land in the plan.

Config rules:

- File path carries placement. `sol/prod/aws/us-east-1.yml` means
  `env=prod`, `provider=aws`, `region=us-east-1`.
- YAML carries topology and overrides: resources, services, bindings, scale,
  sizing, public exposure, durability, and provider-specific knobs.
- Provider-specific fields stay boxed under `aws:` or `gcp:`. Promote a field
  to generic Sol language only when it has stable meaning across providers.
- Local `uses` refs address resources in the selected target. Absolute refs
  use `/<region>/<resource>` and address resources in another region of the
  same env/provider. `sol plan` must print them as cross-region access.
- Refs containing an env segment, such as `/prod/aws/us-east-1/db`, are invalid;
  cross-env sharing is not supported.
- Refs containing a provider segment, such as `/gcp/us-central1/db`, are
  reserved for future multi-cloud support and rejected in v1.
- Cross-target access is not replication. Replication requires explicit future
  language such as `replica_of` or `replicate_from`.
- Folder config and nested YAML are two projections of the same logical model;
  adding split/flat formatters later must not change deploy semantics.

## Project 4: Worker Retry Contract

Make Kafka failure behavior explicit before production users invent variants.

Completion criteria:

- Worker config supports max attempts and local retry backoff.
- Failed messages go to `<topic>.dlq` after attempts are exhausted.
- DLQ events include original topic, partition, offset, attempt count, error,
  and first-seen timestamp.
- Successful DLQ publish commits the original offset.
- Handlers are documented as requiring idempotency.

Tests:

- Unit test for retry count and backoff decision.
- Redpanda integration test for DLQ publish plus original offset commit.
- Failure test where DLQ publish fails and the original offset is not committed.

## Project 5: Release/Upgrade Loop

Make deploy, inspect, rollback, and upgrade understandable from Sol commands.

Completion criteria:

- Every deploy writes a local or remote release record with service image refs.
- `sol status` shows desired tag, live tag, rollout state, and age.
- `sol rollback <service>` works for Deployments and Rollouts.
- CronJobs report as non-rollout workloads instead of pretending rollback works.
- Reusing a fixed tag forces a rollout restart or is rejected with a clear fix.

Tests:

- Release record serialization tests.
- Kubernetes command adapter tests for restart/status/rollback.
- Dry-run fixture showing status/rollback behavior for svc, worker, and fn.

## Not Yet

- Active-active multi-region.
- Automatic cross-region Kafka failover.
- Lambda deploys from Sol.
- A hosted control plane.

Add these when the single-region Kubernetes path is proven live and boring.
