# GCP Attempt 28 — the application row, end to end

## Summary

| | |
|---|---|
| revision | `074b0cac` (the reverted in-cluster gate) + the two follow-ups in this change |
| target | `qual28/gcp/us-central1`, cluster `sol-qual-gcp-28`, project `sol-qualification` |
| evidence | `/tmp/sol-gcp-qual-28/` (machine-local; this record is the durable account) |
| result | **the row completed**: substrate → platform `Ready` → build → push → `migrate apply` → `deploy` → transaction → supported teardown → independently verified absence |
| residue after | none attributable to qualification; the durable state bucket and delegation zone remain by contract |

## Boundaries, in order

| # | boundary | evidence |
|---|---|---|
| 1 | cloud plan + apply, cluster created | kubeconfig established 09:43:20 up while the cluster became `RUNNING`; run-kubeconfig waiter, 62 polls |
| 2 | platform install | "the platform install returned success" 10:41:23; Ready-path evidence captured (`ready-phases.txt`, `ready-pods.log` 82 lines) |
| 3 | build + push | both images built and pushed into `us-central1-docker.pkg.dev/sol-qualification/sol-qual-gcp-28` |
| 4 | `sol migrate apply` | ok 10:58:27 (4m48s) |
| 5 | `sol deploy` | ok |
| 6 | transaction | ok 10:58:57 — *"a charge was accepted, the worker consumed it, and the service read the worker's row back out of PostgreSQL"* |
| 7 | supported teardown | `Done. Destruction reached verified absence.` |
| 8 | independent inventory | no clusters, instances, addresses, networks, routers, disks, service accounts or custom roles attributable to qualification |

The transaction is the causal path, not a health check: the charge is accepted over HTTP, the event
travels through Kafka, the worker consumes it and writes PostgreSQL, and the service reads the row the
worker wrote back out of the database. The harness fails the phase on any leg, so a healthy pair of pods
cannot report success.

## What the row found, in the order it found it

**1. The in-cluster gate I added was itself the defect — three times.** Attempt 26 could not plan: with
the bootstrap window open, `local.needs_kubernetes` was true and the provider's `host` came from a
`data` source reading a cluster the apply had not created (`clusters/sol-qual-gcp-26 not found`); a data
source is resolved when the configuration is evaluated and cannot be deferred, while a managed
resource's attribute can. Attempt 27 got through the substrate and the cluster and then failed twice on
the same thing: `provisioner-bootstrap-access-remove` *deletes* the binding through that provider, and so
does the destroy while the binding is in state — with the provider switched off, an empty host is read as
`http://localhost` and the delete is refused. Each fix invited the next: gating on the binding broke the
relinquish; gating on the operation layer broke the destroy. The gate was reverted to the original
resource-derived provider and ungated binding (#710).

The evidence that the revert is right is that it converged Attempt 27's standing substrate — cluster,
node pool, Cloud SQL instance, VPC, subnet, router, NAT, addresses — to `verified absence` through the
supported destroy, where the gated code had refused it, with no manual repair.

What the revert costs is stated rather than hidden: adopting a substrate resource while its cluster is
**absent** is no longer possible, because the cluster root cannot be evaluated. The reconciler reports
that failure and refuses — the fail-closed behaviour the invariant asks for — and that narrow case ends
in operator disposal, as Attempt 25's did. The realistic ambiguous-outcome case (an interrupted apply
with the cluster still present) is unaffected.

**2. A qualification-machinery defect.** The harness re-derived `PROJECT` and `REGION` from their
defaults without exporting them, and the app helpers run through `bash -c "$(declare -f ...)"` — a fresh
process that sees only the environment. The app phase built `-docker.pkg.dev//sol-qual-gcp-28/...` and
docker rejected the tag. Same class as the empty `APP_TAG` fixed earlier in the same harness.

**3. A product defect the row existed to find.** The teardown failed:

```text
Error: failed to delete user postgres in instance sol-qual-gcp-28-postgres: role "postgres"
cannot be dropped because some objects depend on it. Details: 3 objects in database app
Error: failed to delete database app: database "app" is being accessed by other users
```

`google_sql_database.app` and `google_sql_user.postgres` are siblings, so Terraform deleted them
concurrently — and the application's migrated schema objects depend on the role, so whichever order won,
the role refused to go. The database now depends on the user: destruction drops the database first,
which removes its objects, and then the role has no dependents. Verified by re-running the teardown that
had failed, which reached verified absence.

The second line — `database "app" is being accessed by other users` — was observed only on the first
teardown, after the platform teardown had already removed the workloads. It did not recur on the re-run,
so it is recorded as an un-reproduced observation, most likely a connection from a terminating pod. It is
**not** claimed as fixed, and not attributed to the ordering change.

## Findings

- **FND-0070** — carried here rather than widened: the gate is reverted, the reconciler stays exact and
  fail-closed, and no provider-side mutation exists anywhere in the product.
- The SQL database/role ordering is a product defect of the same family as FND-0070's subject (a teardown
  that cannot converge), but it is not that finding: it is an implicit-ordering defect inside a root, and
  it is fixed in the root rather than in the lifecycle.

## What this does not establish

- No claim about GCP's production profile: the row's target selects **no profile**, so it claims nothing
  the production profile's guarantees would promise (`production_qualified = false` for GCP).
- Nothing about public DNS publication. The delegation hand-off is a documented operator step
  (`docs/guides/TUTORIAL.md`), and the row's two services declare no ingress host, so the application
  contract exercised here does not include public reachability. The TLS path was established separately
  in Attempt 19 (verified by SNI, not by `Ready=True`).
