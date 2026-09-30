---
id: FND-0077
type: audit-finding
severity: high
source: GCP application row (sol-qual-gcp-29) — the supported destroy could not drop the database
---

**Depends on:** None.

**Related:** `platform/cloud/gcp/cluster/main.tf` (`google_sql_database.app`),
`internal/qualification/records/2026-09-30-gcp-application-row-under-enforced-policy.md`,
FND-0058 (the earlier sibling-ordering defect in the same teardown).

# Destroy asks the provider to drop the database while the deployed workloads still hold connections

## What happened

The supported teardown of the GCP application row converged on the cluster, the workloads and the
network, and then stopped on the database:

```
Error: Error when reading or editing Database: googleapi: Error 400: Invalid request: failed to
delete database app. Detail: pq: database "app" is being used by other users., invalid
```

Sol reported it honestly — *"Destruction did not converge … What remains is whatever the
verification above reports; nothing here establishes that the resources are gone."* — and nothing
was deleted at the provider by hand. The specimen was then destroyed by re-running the same
supported destroy once the cluster (and with it the pooled connections) was gone, which reported
verified absence.

## Why

The application workloads run a connection pool against the managed database and hold those
connections open for their lifetime. The lifecycle removes the cluster-side resources and asks the
provider to drop the `app` database in the same run, and the drop lands while the pool's sessions
are still open. This is the same *shape* as FND-0058 — a sibling ordering defect fixed by making
`google_sql_database.app` depend on `google_sql_user.postgres` — but the dependency here is not
between two Terraform resources: it is between Terraform's database deletion and the **cluster**
state that Sol removed earlier in the same run.

Only GCP exposes it, because the AWS root does not manage a database object whose deletion is
refused by open sessions.

## Acceptance criteria

- A supported destroy of an application row converges on the first attempt, with the workloads that
  Sol deployed no longer holding connections when the database is dropped — by removing or scaling
  them as part of the destroy, or by waiting until the provider reports the sessions gone.
- The teardown does not depend on a second invocation, and does not require an operator to delete
  anything at the provider.
- Coverage: an offline scenario in which a database deletion is refused because a session is open
  converges once the workloads are removed, and a deletion refused for any other reason still fails
  closed.
