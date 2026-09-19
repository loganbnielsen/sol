# Production state bootstrap, identities and recovery (AUDIT-072)

`production-single-region` requires infrastructure state that is encrypted,
versioned and locked, and named provisioning/deploy/operator identities distinct
from the cluster-creator admin. This is the AWS bootstrap for the one qualified
provider; provider parity is not part of maturity A.

Implementation and offline validation live here; the destructive recovery and
authorization checks are HARDEN-002's.

## 1. Provision the state backend (Sol provisions it by default)

A Terraform configuration cannot create its own backend, so the backend is a
small separate root:

```bash
cd cli/platform/infra/bootstrap
terraform init
terraform apply \
  -var="region=us-east-1" \
  -var="state_bucket=<globally-unique-name>" \
  -var="state_lock_table=<name>"
```

It creates:

- an S3 bucket with **versioning**, **AES256 encryption** and a full
  **public-access block** — object versioning is the recovery mechanism;
- a **DynamoDB lock table** (`LockID`) so two concurrent applies serialize or
  one is rejected without corrupting state.

Bring-your-own is a documented alternative: any backend with the same
properties (encrypted, versioned, locked) is conformant. Record it in the target
so preflight can verify it:

```yaml
target:
  profile: production-single-region
  state_bucket: acme-tfstate
  state_lock_table: acme-tflock
  letsencrypt_email: ops@acme.example
```

`sol cloud` fails closed before Terraform initialization when either is missing.
It supplies this configuration at runtime and uses deterministic, distinct
`sol/<target>/cloud.tfstate` and `sol/<target>/platform.tfstate` objects. Do not
create a repository or operator-managed `backend.tf` for the normal lifecycle.

## 2. Identities: Sol generates the contracts, you supply the ARNs

The bootstrap root outputs four least-privilege policy documents
(`provisioner_policy_json`, `publisher_policy_json`, `deploy_policy_json`,
`operator_policy_json`). Sol owns the *contract*; it does not create roles,
attach policies, or manage their lifecycle. Create the roles in your account
and declare the three ARNs `sol deploy` actually reads:

```yaml
target:
  provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
  deploy_role_arn:      arn:aws:iam::111122223333:role/sol-deploy
  operator_role_arn:    arn:aws:iam::111122223333:role/sol-operator
  cluster_endpoint_cidr: 203.0.113.0/24
```

The boundary the contracts encode:

- **provisioner** — a constrained high-privilege identity that creates/updates
  cloud and platform infrastructure, including the workspace's ECR
  repositories (their *lifecycle* — create/describe/tag — never the data-plane
  actions that would let it push an image into one; that deny is explicit in
  the generated policy, not just an omission). Its direct Kubernetes grants
  cover the supported platform lifecycle in platform namespaces and exclude
  ordinary application mutation elsewhere; CRD/controller authority still
  makes it a powerful infrastructure trust domain;
- **publisher** — may push/replace images in the workspace's ECR repositories
  (`ecr:PutImage` and its supporting layer-upload actions) and nothing else;
  explicitly denied infrastructure, IAM, and repository-lifecycle mutation, so
  publishing an image cannot also grant provisioning or deploy authority. No
  target field names this ARN — Sol's own execution never resolves it.
  `sol up` never touches AWS at all (local-only, no target concept); a CI
  pipeline authenticates as this identity for its own `docker push` step,
  entirely outside Sol, before calling `sol deploy` with the resulting digest;
- **deploy** — may `DescribeCluster` and mutate application objects through a
  namespace-scoped EKS access entry. It explicitly **denies** infrastructure and
  IAM mutation and any attempt to grant itself cluster administration, so it
  cannot escalate;
- **operator** — read access to the cluster and state for day-to-day work.

`sol deploy` fails closed unless the three ARNs it reads (provisioner, deploy,
operator) are present and the public API endpoint is restricted to an
explicit CIDR (`0.0.0.0/0` is rejected). A public endpoint with an explicit
CIDR allowlist is acceptable for maturity A;
private-only networking is a stronger future posture.

### Configuring kubectl for the deploy identity

`sol cloud apply` wires `deploy_role_arn` into an EKS access entry (Kubernetes
group `sol:deployers`) and a cluster-wide `sol-deploy` `ClusterRole`; the
namespace-scoped `RoleBinding` that actually grants it is applied per
application namespace at deploy time (`Sol_cli_substrate.ensure`), not by
Terraform, since application namespaces are created dynamically. Once the role
exists and `deploy_role_arn` is set, `sol cloud apply`'s output prints the
command to run — Sol does not write your kubeconfig or the target file for
you (AUDIT-072: Sol owns the IAM policy contract, not your local kubeconfig
or role lifecycle):

```
deploy_kubeconfig_command   aws eks update-kubeconfig --region us-east-1 --name <cluster> --alias <cluster>-deploy --role-arn arn:aws:iam::111122223333:role/sol-deploy
deploy_kube_context         <cluster>-deploy
```

Run the printed command, then add the printed context name to the target:

```yaml
target:
  kube_context: <cluster>-deploy
```

## 3. No standing cluster-creator admin

The AWS module sets `enable_cluster_creator_admin_permissions = false`. During
`sol cloud apply`, the named provisioner holds temporary EKS bootstrap admin
access for the whole privileged `PlatformInstalling` phase — the full platform
apply and verified readiness — because installing cluster-wide software that
mints RBAC is itself privileged platform establishment (ADR 0003). Sol then
removes the managed admin association and verifies the effective positive and
negative RBAC boundary, so the steady-state provisioner never holds
`escalate`/`bind` and cannot manufacture a more powerful identity. An interrupted
run is safely re-runnable and reconciles that temporary association away; it is
not the steady-state access model.

## 4. Recovery procedure

Control-state RTO is procedure-based, not a numeric bound (DEC-026 §5).

**Recover a clean runner** (original runner and local files gone):

```bash
sol cloud plan prod/aws/us-east-1
sol cloud apply prod/aws/us-east-1
```

**Recover a prior state object version** (bad apply, or corrupted state):

```bash
aws s3api list-object-versions --bucket <bucket> --prefix sol/prod/aws/us-east-1/
aws s3api get-object --bucket <bucket> --key sol/prod/aws/us-east-1/cloud.tfstate \
  --version-id <version-id> /tmp/tfstate.recovered
# Inspect, then restore the chosen version explicitly — never in place blindly.
```

**Two concurrent mutations** serialize through the lock table; if the lock is
stale, `terraform force-unlock <lock-id>` is the operator's explicit override.

## Evidence HARDEN-002 records

- two concurrent applies serialize or one is rejected without corrupting state;
- a clean runner recovers the backend and plans with no unintended recreation;
- recovery from a prior backend object version is exercised;
- the deploy identity is denied an infrastructure mutation and a self-granted
  admin policy;
- the ordinary operator path does not use the cluster-creator credential;
- one infrastructure and one application mutation are attributed to their named
  principal in retained audit evidence.

## Credentials and Terraform variable ownership

Two things learned by qualifying a real target (HARDEN-002 run 1), both now
enforced in code rather than in an operator's memory.

**The database master password is supplied out of band.** The provider root
creates the RDS instance, so it needs a master password before any workload
exists. Supply it through the environment, never as a Terraform variable on the
command line:

```bash
TF_VAR_db_password="$(your-secret-tool get sol-db-password)" \
  sol cloud apply prod/aws/us-east-1
```

Sol refuses an apply that would create Postgres with no credential source, and
refuses a password passed with `--var` — the run log records the terraform
command line verbatim, so the value would be written to a file. The module
carries the same precondition on `aws_db_instance.postgres`, so the constraint
holds even when terraform is driven directly. Nothing writes the password to a
plan, an output, a log or a release record; the module's `postgres_url` output
(which does contain it) is `sensitive`, and it exists so an operator can place
the connection string in their secret store for the runtime Secret that
workloads read as `POSTGRES_URL`.

**`cluster_issuer` belongs to the base platform layer.** `sol cloud plan/apply/
destroy` pass each Terraform root only the variables it declares.
`cluster_issuer` names a cert-manager `ClusterIssuer`, so Sol routes it to
`cli/platform/infra/base` after the cloud output contract has been validated.

It remains a target field (`sol deploy` uses it for ingress annotations). Passing
it to the provider root, as it used to be, made terraform abort with "a variable
named cluster_issuer was assigned on the command line, but the root module does
not declare a variable of that name" — so a documented target using it could not
provision at all.

## Platform storage (finding 7 of HARDEN-002 run 2)

The qualified substrate must be able to host the platform's own durable
components. Two layers provide that, and neither is an application workload volume:

- **Cloud substrate**: on AWS (`cli/platform/infra/aws`) this installs the **EBS
  CSI driver** as an EKS addon, with an IRSA role scoped to
  `kube-system:ebs-csi-controller-sa`. Without it an EKS cluster has no CSI
  driver and therefore no StorageClass, so every PVC stays `Pending`. On GCP the
  `pd.csi.storage.gke.io` driver is part of GKE itself and needs no addon.
- **Platform substrate** (`cli/platform/infra/base`) creates the default **gp3
  StorageClass** on AWS (`WaitForFirstConsumer`, so the volume is created in the
  zone the pod lands in). Set `create_storage_class = false` if the platform is
  expected to adopt a class that already exists, or `storage_class_name` to rename
  it.
- **On GCP the module creates no class and adopts GKE's own default**
  (`standard-rwo`, provisioner `pd.csi.storage.gke.io`, `WaitForFirstConsumer`,
  `pd-balanced`). GKE already annotates it as the default, and the platform's PVCs
  name no `storageClassName`, so they bind to whatever the cluster calls default.
  Creating a second default class would leave the cluster with two, which
  Kubernetes accepts with a warning and then resolves arbitrarily. Persistent
  Disks are encrypted at rest with Google-managed keys by default, so the posture
  the AWS class states explicitly (`encrypted = "true"`) holds here without a
  parameter.

`Ready` asserts the outcome for either provider rather than trusting the
configuration that produced it: the provider's class is the *sole* default
StorageClass on the cluster and is backed by the provider's block-storage CSI
driver, which is registered (`Sol_cli_cloud_lifecycle.platform_storage`). A
cluster whose default is some other class, or whose default is ambiguous, is
`Unmet` — the platform's durable volumes are then not on the class Sol intends.

This is what makes Redpanda's RF≥3 persistent brokers schedulable. It changes
nothing about how a workload declares persistence: the `single`-tier restriction
DEC-026 §3 puts on workload-declared volumes is unaffected, because the driver and
the class are platform capabilities, not a workload's storage claim.

Before run 2 the substrate had neither, and the only reason the repository's own
live smoke harness ever installed the platform was that it disabled persistence
(`-var=redpanda_persistent_storage=false`).

## Platform roots are selected per provider

The platform *definition* is `cli/platform/infra/base`. A Terraform root's state
backend *type* is part of its own configuration — `-backend-config` sets
attributes, never the type — so one root cannot serve both the S3 backend AWS
needs and the GCS backend GCP needs. `sol cloud` therefore selects a root per
provider (`Sol_cli_cloud_lifecycle.platform_root`):

| Provider | Root | Backend | Platform state object |
|---|---|---|---|
| AWS | `cli/platform/infra/base` | S3 + DynamoDB locking | `sol/<target>/platform.tfstate` (`key=`) |
| GCP | `cli/platform/infra/base-gcp` | GCS, native locking | `sol/<target>/platform.tfstate` (`prefix=`) |

`base-gcp` declares only the GCS backend and a module call into `base`, so the
definition itself is not duplicated. Two consequences are worth knowing before
editing either:

- A module's own `terraform` block is ignored, so `terraform init` on `base-gcp`
  warns about `base`'s S3 backend and provider requirements. That is expected —
  the root's backend is the one used, and supplying it is the whole reason the
  root exists.
- The GCP root mirrors every variable in the definition except the AWS-shaped
  ones — `aws_region`, the S3 buckets and their IRSA roles, and
  `cert_manager_irsa_role_arn`, none of which a GCP install can use. Adding a
  variable to the definition without adding it to `base-gcp` fails
  `cli/sol/test/check_production_infra.sh` rather than silently defaulting on GCP.

Everything a target addresses inside the platform root goes through
`Sol_cli_cloud_lifecycle.platform_address`, because a root that reaches the
definition through a module addresses its resources through it
(`module.platform.<resource>`) while AWS's does not.

## Destroying a target (finding 9 of HARDEN-002 run 2)

Production RDS deletion protection stays **on** by default; that is correct and is
not relaxed for convenience. Destruction is an explicit lifecycle:

1. the operator confirms the target is disposable;
2. deletion protection is disabled **by an applied state transition** — either
   `terraform apply -var=rds_deletion_protection=false` or `aws rds
   modify-db-instance --no-deletion-protection`, followed by waiting for the
   instance to leave `modifying`;
3. Terraform takes a final snapshot. The module sets `final_snapshot_identifier`
   whenever it will take one, defaulting to `<cluster>-postgres-final`. RDS requires
   snapshot names to be unique, so destroying the same cluster name a second time
   needs a fresh `rds_final_snapshot_identifier` **applied in the same step as 2** —
   otherwise the delete fails with `DBSnapshotAlreadyExists`;
4. `terraform destroy` completes;
5. absence is verified independently. `verify_aws_destroy`, which `sol cloud
   destroy` runs, covers EKS, RDS, ECR and load balancers. The live smoke harness
   (`internal/qualification/aws/live-smoke.sh`) additionally asserts the VPC is gone after its
   own `sol cloud destroy`. **Nothing automated checks elastic IPs, NAT gateways
   or EBS volumes** — those remain the manual sweep recorded in HARDEN-002.
   Volumes are worth the operator's attention from this release onward: the EBS
   CSI driver and default gp3 StorageClass (see *Platform storage* above) are what
   first make dynamically provisioned EBS volumes possible on this substrate. The
   class reclaims with `Delete`, but that only fires when the *PVC* is deleted
   through the API — tearing the cluster down without doing so leaves the volumes
   behind.

Passing `-var` to `terraform destroy` does **not** accomplish step 2 or 3. A destroy
plan contains only deletes, so the provider is handed prior state and never sees the
new value: `terraform plan -destroy -var x=B` on an applied `x = "A"` plans
`input = "A" -> null`. Both settings have to be applied *before* the destroy.

That is why preparation is its own **applied transition** on just the database
resource (`INFRA-023`, finding 9b): `sol cloud destroy --apply` runs a targeted
`terraform apply` that disables deletion protection and sets a final-snapshot
identifier unique to that attempt, verifies the preparation landed in state, and
only then destroys. The overrides are appended *after* the profile's
`rds_deletion_protection=true`, so the Destroy policy wins over the Ready policy
for the reconciliation that necessarily precedes the teardown (ADR 0003, finding
15). A re-run after an interrupted destroy mints a fresh snapshot identifier, so a
retry cannot collide with a previous attempt's final snapshot.

## A disposable target must be able to reach `Absent`

The invariant, discovered the hard way on AWS (HARDEN-002 attempt 5) and applied
to both providers rather than to the one resource that exposed it:

> **Normal Sol operation must not make a disposable target impossible to destroy
> through the documented Sol lifecycle.**

`prevent_destroy = true` on the durable telemetry buckets was exactly that defect.
It does not *retain* anything — it makes the whole root undestroyable, so a target
with durable observability could never reach `Absent` and its storage stayed
billable forever. The AWS ECR repository was the same mistake in a different
resource.

What replaced it separates the two things the attribute conflated:

- **`force_destroy`** (both providers, wired to
  `durable_storage_force_destroy`) decides whether a *non-empty* bucket may be
  deleted. Its default is `false`, so a `terraform destroy` driven directly
  discards no telemetry by surprise.
- **The Destroy policy sets it `true`.** Discarding a target's telemetry is a
  decision the phase performing the teardown names, not a resource default that
  assumes it. `sol cloud destroy --apply` therefore deletes the buckets with the
  target.

Retention beyond a target's life is a *facility* concern, not a resource
attribute: objects that must outlive the target have to be owned outside the
target's root (a separate state), because no Terraform attribute can express
"keep this and forget it". A target that wants production-grade retention gets it
by having its telemetry buckets owned elsewhere, not by making its own root
impossible to destroy.

For a **disposable qualification** target, teardown is expected to end at literal
`Absent`: no residual storage, snapshots, addresses, disks or load balancers
unless retention itself is the scenario under test. Production retention
semantics are deliberately different, and explicit — they are not weakened to
satisfy qualification, and qualification does not inherit them by accident.

`cli/sol/test/check_production_infra.sh` asserts the invariant structurally: no
root may use `prevent_destroy`, both providers' buckets must be wired to the
variable, and its default must stay conservative. Mutation-checked against
reintroducing the attribute, breaking the wiring, and flipping the default.

**Not yet live-confirmed:** the bucket deletion path above has been validated
offline (guard + the fake-toolchain lifecycle harness) and by `terraform fmt` /
`validate`, but no live destroy has yet run against a target with durable
observability enabled. That is the first thing the qualification run should
exercise, on both providers.
