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
```

`sol deploy` fails closed before any mutation when either is missing — a local
or unversioned backend is never conformant. Generate the `backend "s3"` body for
the provider root from the `backend_config` output:

```bash
terraform -chdir=cli/platform/infra/bootstrap output -raw backend_config
```

## 2. Identities: Sol generates the contracts, you supply the ARNs

The bootstrap root outputs three least-privilege policy documents
(`provisioner_policy_json`, `deploy_policy_json`, `operator_policy_json`). Sol
owns the *contract*; it does not create roles, attach policies, or manage their
lifecycle. Create the roles in your account and declare their ARNs:

```yaml
target:
  provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
  deploy_role_arn:      arn:aws:iam::111122223333:role/sol-deploy
  operator_role_arn:    arn:aws:iam::111122223333:role/sol-operator
  cluster_endpoint_cidr: 203.0.113.0/24
```

The boundary the contracts encode:

- **provisioner** — creates/updates the cluster and its infrastructure;
- **deploy** — may `DescribeCluster` and mutate application objects through a
  namespace-scoped EKS access entry. It explicitly **denies** infrastructure and
  IAM mutation and any attempt to grant itself cluster administration, so it
  cannot escalate;
- **operator** — read access to the cluster and state for day-to-day work.

`sol deploy` fails closed unless all three ARNs are present and the public API
endpoint is restricted to an explicit CIDR (`0.0.0.0/0` is rejected). A public
endpoint with an explicit CIDR allowlist is acceptable for maturity A;
private-only networking is a stronger future posture.

## 3. No standing cluster-creator admin

The AWS module sets `enable_cluster_creator_admin_permissions = false` by
default. Bootstrapping or break-glass that genuinely needs the cluster-creator
credential is a **scoped exception**:

```bash
cd cli/platform/infra/aws
terraform apply -var="enable_cluster_creator_admin=true"   # bootstrap only
terraform apply -var="enable_cluster_creator_admin=false"  # return to normal
```

## 4. Recovery procedure

Control-state RTO is procedure-based, not a numeric bound (DEC-026 §5).

**Recover a clean runner** (original runner and local files gone):

```bash
cd cli/platform/infra/aws
terraform init   # reads the remote backend; no local state needed
terraform plan   # expect no unintended recreation
```

**Recover a prior state object version** (bad apply, or corrupted state):

```bash
aws s3api list-object-versions --bucket <bucket> --prefix sol/terraform.tfstate
aws s3api get-object --bucket <bucket> --key sol/terraform.tfstate \
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
  sol cloud apply prod/aws/us-east-1 --apply
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
destroy` drive `cli/platform/infra/<provider>` and pass that root only the
variables it declares. `cluster_issuer` names a cert-manager `ClusterIssuer`,
which `cli/platform/infra/base` owns, so it is applied there:

```bash
terraform -chdir=cli/platform/infra/base apply -var="cluster_issuer=letsencrypt-prod" ...
```

It remains a target field (`sol deploy` uses it for ingress annotations). Passing
it to the provider root, as it used to be, made terraform abort with "a variable
named cluster_issuer was assigned on the command line, but the root module does
not declare a variable of that name" — so a documented target using it could not
provision at all.

## Platform storage (finding 7 of HARDEN-002 run 2)

The qualified substrate must be able to host the platform's own durable
components. Two layers provide that, and neither is an application workload volume:

- **Cloud substrate** (`cli/platform/infra/aws`) installs the **EBS CSI driver**
  as an EKS addon, with an IRSA role scoped to
  `kube-system:ebs-csi-controller-sa`. Without it an EKS cluster has no CSI
  driver and therefore no StorageClass, so every PVC stays `Pending`.
- **Platform substrate** (`cli/platform/infra/base`) creates the default **gp3
  StorageClass** (`WaitForFirstConsumer`, so the volume is created in the zone the
  pod lands in). Set `create_storage_class = false` if the platform is expected to
  adopt a class that already exists, or `storage_class_name` to rename it.

This is what makes Redpanda's RF≥3 persistent brokers schedulable. It changes
nothing about how a workload declares persistence: the `single`-tier restriction
DEC-026 §3 puts on workload-declared volumes is unaffected, because the driver and
the class are platform capabilities, not a workload's storage claim.

Before run 2 the substrate had neither, and the only reason the repository's own
live smoke harness ever installed the platform was that it disabled persistence
(`-var=redpanda_persistent_storage=false`).

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
5. absence is verified independently. `sol cloud destroy` checks EKS, RDS, ECR and
   load balancers (`verify_aws_destroy`); the live smoke harness checks EKS and
   VPC. **Nothing automated checks VPCs left by a `sol cloud destroy`, elastic IPs,
   NAT gateways, or EBS volumes** — that remains the manual sweep recorded in
   HARDEN-002. Volumes are worth the operator's attention from this release
   onward: the EBS CSI driver and default gp3 StorageClass below are what first
   make dynamically provisioned EBS volumes possible on this substrate. The class
   reclaims with `Delete`, but that only fires when the *PVC* is deleted through
   the API — tearing the cluster down without doing so leaves the volumes behind.

Passing `-var` to `terraform destroy` does **not** accomplish step 2 or 3. A destroy
plan contains only deletes, so the provider is handed prior state and never sees the
new value: `terraform plan -destroy -var x=B` on an applied `x = "A"` plans
`input = "A" -> null`. Both settings have to be applied *before* the destroy.

**Known gap:** `sol cloud destroy` therefore cannot yet destroy a protected
production RDS instance. It runs the destroy only; it performs no preparatory
transition, and a `-var` it forwarded would be inert for the reason above. Until the
preparation step exists, the operator performs steps 2 and 3 directly (via
`terraform apply` or the `aws` CLI) and may then use either `terraform destroy` or
`sol cloud destroy <target> --apply`.

What is fixed here is the Terraform-level defect: `skip_final_snapshot` is no longer
derived from `deletion_protection` — so permitting destruction no longer means
silently forgoing the final snapshot — and an identifier is always set when a
snapshot will be taken, so Terraform no longer refuses the destroy outright. Making
destruction a *Sol* operation (prepare → verify the transition landed → destroy →
verify absence, with a unique snapshot identity per attempt) is separate work,
sequenced with the provisioning lifecycle rather than bolted onto the destroy
invocation.
