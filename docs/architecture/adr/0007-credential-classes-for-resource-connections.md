# ADR 0007: Credential classes for resource connections

## Status

Proposed. Gates #1344d PR 2 (role-separated delivery).

## Context

Dependency-scoped delivery answers *who receives a credential*. It does not answer *what that
credential authorizes*, and today the two are conflated in a way that is a security defect, not a
scoping detail:

- Both providers' `postgres_url` output is
  `postgresql://postgres:${var.db_password}@…` — the same `db_password` used to create the instance
  and its master user. **It is the administrative credential.**
- The migration Job consumes it (`verify_runtime_secret ~required_keys:["POSTGRES_URL"]`), and every
  unit requires it (`default_secrets = ["POSTGRES_URL", ""]`).

So "deliver the bound connection to declared consumers" would have handed ordinary workloads
administrative database access. `docs/architecture/resource-bindings.md` §3.2 fixes the shape:

| Class | Held by | Delivered? |
|---|---|---|
| Provisioning (administrative) | Sol's provisioning path | Never delivered to a consumer |
| DDL (schema changes) | The migration Job | To the migration Job only |
| DML (ordinary operations) | Application workloads | To declared consumers |

The class is **derived from the consumer's role**, so there is no user declaration and no permission
DSL. This record settles the four mechanics the model leaves open.

**Constraints found in the current implementation**, which decide the design:

- `platform/cloud/{aws,gcp}` declare **no additional PostgreSQL users**: only the master. PostgreSQL
  roles require SQL; no Terraform resource creates them.
- The database is **private** (GCP `ipv4_enabled = false`; the AWS instance is in private subnets), so
  an out-of-cluster Terraform SQL provider cannot be assumed to reach it.
- There is **no install-time Job machinery**; the only in-cluster one-shot runner is the migration Job
  (`sol_cli_migration_job.ml`: render, apply, wait, clean up).
- The migration Job is a **consumer**. It must not hold the provisioning credential, or the property
  this ADR establishes is defeated at the first step.

## Decision

### 1. Roles and grants

| Class | Role | Grants |
|---|---|---|
| **Provisioning** | The provider's master user (`postgres`, `var.db_password`) | Instance administration. Held by the provisioning path; never delivered |
| **DDL** | `sol_migrator` | Create and alter objects in the application schema |
| **DML** | `sol_app` | DML on the application schema; no DDL |

**No DML sub-classes yet** — read-only/read-write or per-table grants are deferred until a concrete
consumer requires one.

### 2. Source per class

**Sol-provisioned resource.** The provisioning configuration produces only the master credential. A
**database setup step** then runs *in-cluster*, with the master credential, to create or update
`sol_migrator` and `sol_app` with Sol-generated passwords, and records them in the target's
Sol-managed Secret. The binding's connection contract carries **one source per class** pointing at
those entries, and delivery reads the source for the class the consumer's role implies. Sol generates
the passwords — the operator supplies nothing.

**External resource.** The binding declares **one remote path per class** (the store holds one
credential per class), or a single path carrying a field per class. An external resource with no
source for a class simply has no consumer of that class; a consumer needing a class with no source
fails the plan (§3).

### 3. Enforcement

- The class is a **property of the consumer kind**: migration Job → DDL; unit → DML.
- The check lives in **resolution, beside the one-producer rule** (`Sol_cli_resource_binding.resolve`
  today): a resolved binding must offer a source for exactly the class the consumer's role implies.
  A consumer whose role implies a class the binding cannot source **fails at plan**; the provisioning
  class is never selectable by a consumer.
- Criterion 19 is the test: a workload's rendered inputs never contain the DDL or the provisioning
  credential, and the migration Job's never contain the DML credential.

### 4. Writers

**One delivered object per class per consuming namespace**, each with exactly one writer: Sol's
provisioning/database-setup path for a Sol-provisioned resource, ESO for an external one. A class with
no consumer in a namespace is not delivered, so a target that declares no migrations has no DDL object.

## Consequences

- **New machinery: one in-cluster database setup step.** It applies a Job with the master credential,
  waits, and records the generated credentials. It reuses the existing Job mechanics rather than
  introducing a runner concept — but it is new code and is the cost of this decision. There is no
  Terraform-only path: no role resource exists, and the database is unreachable from Terraform.
- **Storage.** The generated DDL and DML passwords are Sol-managed secrets in the target's Kubernetes
  Secret for v1 — the store the model names (§3.1). Their durability and any move to a provider store
  belong to #1360.
- **The plan gains a class refusal**, not a new declaration.
- **The migration Job's inputs change** from the master `POSTGRES_URL` to the DDL credential, and
  `default_secrets`' `POSTGRES_URL` entry goes away.

## Alternatives considered

1. **Terraform's PostgreSQL provider** (`postgresql_role`, `postgresql_grant`) — declarative, no new
   Job. Rejected: requires network reachability to a private database from wherever Terraform runs.
2. **The migration Job creates the roles with the master credential** — rejected: it makes a consumer
   hold the provisioning credential, defeating the property; and a target with no migrations runs no
   Job, so the DML role would never exist.
3. **The operator creates the roles** — rejected: it contradicts the standard that declaring a
   dependency is enough for Sol to provision, connect and operate.
4. **One shared non-admin credential for DDL and DML** — rejected: collapses the classes and makes the
   criterion vacuous.
5. **A permission or grant DSL** — rejected: roles are enumerated by consumer kind, never configured.

## References

- `docs/architecture/resource-bindings.md` §3.1, §3.2, §4, criterion 19
- `platform/cloud/aws/cluster/outputs.tf`, `platform/cloud/gcp/cluster/outputs.tf` (`postgres_url`)
- `cli/lib/deploy/sol_cli_secret.ml` (`verify_runtime_secret`),
  `cli/lib/workspace/sol_cli_manifest_yaml.ml` (`default_secrets`)
- `cli/lib/deploy/sol_cli_migration_job.ml` (Job mechanics)
- #1344 (implementation), #1360 (authoritative storage)
