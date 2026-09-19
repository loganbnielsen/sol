# INFRA-042 — a partially-installed GCP platform is not destroyable through the lifecycle

**Status:** Done
**Severity:** high
**Discovered:** GCP qualification Attempt 3 (2026-09-19)

## What happened

Attempt 3 reached `PlatformInstalling` under the scoped authority model and failed
there (the host lacked `gke-gcloud-auth-plugin`; that part is fixed separately,
because a host prerequisite should be refused before a billable apply rather than
inside one).

Sol's documented destroy then ran and could not complete the teardown:

```
[gcp-destroy-prepare] ok (20.3s)
  lifecycle phase: PreparingDestroy
[destroy-reconciliation-apply] ok (10.2s)
[platform-destroy] FAILED (38.0s)
    │ Error: API did not recognize GroupVersionKind from manifest (CRD may not be installed)
[provisioner-bootstrap-access-remove] ok (9.0s)
exit=1
```

The platform root's state referenced CRD-backed resources whose CRDs were never
installed, because the install never got far enough to install them. The
Kubernetes provider cannot delete a resource whose API does not exist, so the
destroy fails — and the cloud layer behind it is billable.

## Why this matters

This is ADR 0004's invariant reached through a **third** mechanism, and the first
two already have guards:

1. `prevent_destroy = true` — found by `check_destroy_completeness.sh`;
2. a provider-level deletion default (GKE's `deletion_protection`) — found by
   Attempt 1 and now guarded;
3. **a resource whose API does not exist at destroy time** — the case here.

"Normal Sol activity must never make a target undeletable through the normal
lifecycle" has to hold for a *failed* install, not only a successful one. A failed
install is the state a target is most likely to be in.

## Fix

Terraform's destroy is attempted first, in full, with its own ownership and ordering.
Only when it has actually failed does Sol consider which state entries cannot
correspond to an object, and the proof is the cluster's own discovery
(`kubectl api-resources --verbs=delete`), deliberately narrow:

- only `kubernetes_manifest`, whose stored manifest states its kind verbatim.
  Native `kubernetes_*` resources are not handled: deriving their kind means mapping
  a Terraform type to a Kubernetes kind by convention, and a mapping wrong in the
  wrong direction forgets a resource that exists. A native resource that will not
  delete stays a failure.
- only when the cluster does not serve that kind with `delete`. A served kind means a
  resource that may exist, so nothing is forgotten and a second failure is the
  failure.

Each forgotten address is named with the kind that proved it absent. Regression in
`internal/ci/test_cloud_lifecycle_offline.sh`: it reproduces the missing-CRD failure,
asserts the recovery, the retry and the completed destroy, and pins the opposite
direction -- with the CRD served, no `state rm` happens and the destroy fails closed.
Both directions are mutation-tested.

## Original analysis (kept for the record)

- The failure is specific and detectable: the resource does not exist, and neither
  does its CRD. Removing it from state is then *correct* rather than laundering —
  but only when the CRD's absence is established from the cluster, not inferred
  from the error text.
- Alternatively the platform root could be split so that CRD-installing components
  are a prerequisite whose state can be destroyed independently of the components
  that depend on those CRDs.
- Whichever way, the guard should end up general enough to fail when a *complete*
  install's teardown is the thing that broke.

## Out of scope

The `gke-gcloud-auth-plugin` prerequisite (fixed with this discovery) and the
service-networking peering abandonment, which was independently verified absent in
the same teardown.
