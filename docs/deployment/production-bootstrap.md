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
