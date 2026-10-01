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

## Fixed

Destroy now encodes the reverse of the deployment order. `Sol_cli_cloud_destroy.deps` gained a
`release_workloads` step, called immediately before `destroy_substrate`:

```
discover the Sol-owned workload scope from the cluster
  -> remove the workloads and wait for their pods to go
  -> destroy the substrate
  -> independently verify absence
```

`Sol_cli_workload_scope` performs the discovery. The scope comes from the target's declared
namespaces, read as the deploy identity; what is in them comes from the cluster. In each declared
namespace it lists the workloads Sol deploys, keeps the ones whose **pod template** carries the
ownership label Sol renders (the taxonomy labels — `workspace`, `domain`, `service`, `primitive`,
`release`), removes those by name with `--wait=true`, and waits for the workspace-labelled pods to go
— so the pods and their pooled sessions are gone before the provider is asked to drop the database.
Removal does not depend on the release store, which the cloud layer cannot read without inverting the
library graph (`base <- kube <- workspace <- cloud <- deploy`).

Two corrections were needed to reach that, both recorded below: cluster-wide discovery ran as an
identity that may not read pods, and selecting the workload *objects* by the ownership label matched
nothing, because Sol labels their pod templates rather than the objects.

**The inference it supports, narrowly:** a workload whose pod template is labelled
`workspace=<workspace>` is a workload Sol rendered for that workspace, so the namespace holding it is
a namespace Sol deployed into for this target — and destroying the target removes Sol's workloads in
it. It is *not* a general claim that every object in that namespace is Sol's, and it is not a new
ownership contract: if Sol later gains an explicit ownership label, the selector should move to it.

A release failure is a **degradation**: it is reported and teardown continues, because a teardown
must not be blocked by a step that can fail. Final success stays fail-closed — if the substrate
destroy or the independent absence verification cannot establish convergence, no absence is claimed.

Coverage: `check_workload_release_order.py` with `test_workload_release_order_check.py` (twelve
mutations: release dropped, release failure no longer degrading, a read that goes cluster-wide, a
different label, a release that stops waiting, a selection that reads the workload object instead of
its pod template, a CronJob whose template is no longer located, a removal that selects the objects
instead of naming them, the platform identity instead of the deploy identity, the declared scope
dropped, the library graph inverted, the scope read from the release store), five unit tests on the
workload scope plus the release-before-substrate ordering and the degrading release, and two offline
lifecycle scenarios — one proving the removal precedes the pod wait and the substrate destroy in the
run's own log, one proving a release failure degrades and the teardown still finishes.

## The live acceptance test, and what it disproved

The ordered acceptance test — one fresh GCP specimen where a single supported destroy goes from
running workloads with active DB pools to independently verified absence — was run against the
merged fix and **does not yet pass**.

Two results, both from specimen `sol-qual-gcp-30`:

**1. The platform never reached `Ready`, so no application workloads existed.** `platform-apply`
succeeded, then the lifecycle reported `awaiting platform readiness: 2 check(s) unmet` until the
phase gave up. The ClusterIssuers were healthy in the captured evidence —
`letsencrypt-prod` and `letsencrypt-staging` both `True`, *"The ACME account was registered with the
ACME server"* — so the two unmet checks are almost certainly the DEC-056 platform-certificate gate,
not the ACME account path. Why those certificates did not become ready is **not established**; the
harness captured cert-manager evidence and classified it `UNKNOWN`, which is honest about what it
knew.

**2. The release step cannot discover the workloads at all, and degrades.** With no application
deployed the degrade was harmless, and the destroy converged and reported verified absence — but the
reason it converged is that nothing held a session, so the criterion was never exercised:

```
Releasing the application workloads...
warning: the workloads this target deployed could not be released: exited with code 1: Error from
server (Forbidden): pods is forbidden: User
"sol-qual-gcp-30-provisioner@sol-qualification.iam.gserviceaccount.com" cannot list resource "pods"
in API group "" at the cluster scope: requires one of ["container.pods.list"] permission(s) in
Cloud IAM or a Kubernetes RBAC role with verb "list" for resource "pods".
```

The discovery lists pods **cluster-wide**, and it runs as the **provisioner** identity — which by
design has no cluster-wide pod authority (`sol:platform-provisioners` deliberately grants
namespaced platform work, not application reads). So on a real specimen the sessions would not be
released and the database drop would fail exactly as this finding describes.

The design held where it was supposed to: the failure degraded rather than blocking, and nothing
claimed absence that had not been established.

**The correction is not a widening of platform authority.** The scope must come from the target's
declared namespaces, read with the identity Sol deploys applications with (`sol-deployers`), which
is the same authority the deploy path already uses — the alternative seam that was considered and
set aside in favour of cluster-wide discovery. This finding stays **not met live** until a single
supported destroy converges on a specimen whose application is running with active database pools.

## The second attempt: the release runs, finds the workloads, and cannot remove them

Specimen `sol-qual-gcp-32` reached `Ready` with the namespace-scoped release, deployed
`payments/charge_svc` and `comms/notify_worker`, and ran the transaction — `charge ch_262097`
accepted, consumed by the worker, and read back out of PostgreSQL by the service. A single supported
destroy then invoked the release in the right place, as the right identity:

```
Destroying cloud infrastructure (gcp)...
  lifecycle phase: Destroying

Releasing the application workloads...
  pluto-comms: releasing notify-worker-dbfbc8474-qrcrz, notify-worker-dbfbc8474-tn887
warning: the workloads this target deployed could not be released: exited with code 1: timed out waiting for the condition on pods/notify-worker-dbfbc8474-qrcrz
timed out waiting for the condition on pods/notify-worker-dbfbc8474-tn887. A managed database whose sessions they still hold refuses to be dropped, so the teardown below may not converge; if it does not, nothing here claims it did
[...]
[terraform-destroy] FAILED (613.2s)
    Error: Error when reading or editing Database: googleapi: Error 400: Invalid request: failed to delete database app. Detail: pq: database "app" is being accessed by other users., invalid
```

It *found* the workloads — by their pods — and could not remove them. The release deleted
`deployment,cronjob,job` selected by `workspace=<workspace>` (the pre-fix
`Sol_cli_workload_scope.delete_args`), and **Sol renders the ownership labels on each workload's pod
template, not on the Deployment/Job object's own metadata**. In `sol_cli_manifest_yaml.ml` a
Deployment's own `metadata` is `metadata ~ns ~name` — name and namespace only — while the taxonomy
labels ride on `spec.template.metadata.labels`; a CronJob's ride on
`spec.jobTemplate.spec.template.metadata.labels`. A selector on the objects therefore matched
nothing, `kubectl delete` reported success having deleted nothing, the pod wait then timed out, and
the database drop failed exactly as this finding describes.

The failure degraded rather than blocking, and nothing claimed absence. The harness's own
independent inventory recorded `gke-cluster absent`, `subnetwork/router/NAT/disks/forwarding-rules
absent`, and:

```
  ✗ sql-instance still exists (PRESENT)
  ✗ network still exists (PRESENT)
  ✗ address-regional still exists (PRESENT)
  ✗ address-global still exists (PRESENT)
teardown NOT verified: resources remain
```

**The correction changes only the discovery, and keeps the seam.** The release lists the workloads in
each declared namespace, selects the ones whose *pod template* carries the workspace label, removes
those by name — `deployment/<name>`, `cronjob/<name>`, `job/<name>`, which is also how
`Sol_cli_rollback.prune_workloads` already removes a workload — and then waits for the
workspace-labelled pods to go. Naming the objects rather than selecting them also keeps the removal
off the deploy identity's permissions for the other objects that can share a workload's name in the
same namespace, and keeps a partial failure from skipping the wait that closes the sessions.

Coverage moved with it: the unit tests pin the pod-template shape for `Deployment`, `Job` and
`CronJob` explicitly, pin that an object labelled on its own metadata is *not* selected, and pin that
the removal names what it found instead of selecting it; `check_workload_release_order.py` and its
mutation suite gained the two corresponding checks; and the offline lifecycle scenario now asserts
the removal precedes the pod wait, and the wait precedes the substrate destroy.

Two limits are worth stating rather than leaving implicit. A Sol-rendered migration or contract `Job`
carries no taxonomy labels on its template at all, so it is not discoverable this way — those are
short-lived and hold no pool, which is why the ownership label is still the right selector. And a
workload kind that Sol deploys but this listing does not name would not be seen: today that is only
an Argo `Rollout`, which the `-svc` primitive renders for a progressive-delivery service.

