# FND-0004 — A partially installed GCP platform was not destructible through the lifecycle

- **Classification:** `VERIFIED_DEFECT`
- **State:** `FIXED_UNQUALIFIED` (fix #362 merged; GCP Attempt 4 destroyed a
  partially-installed platform through the documented lifecycle with no emergency
  cleanup — but the record does not establish that it exercised the missing-CRD
  recovery path specifically)
- **First identified:** 2026-09-19 (GCP qualification Attempt 3)
- **Last verified:** 2026-09-19, `main @ 910a59f1` (reconciled after #362 / Attempt 4)
- **Provider:** GCP / GKE
- **Derived ticket:** **INFRA-042** (`internal/pipeline/tickets/DONE/INFRA-042.md`)
- **Related invariant:** `INV-DESTROY-1`
- **Related decisions:** ADR 0003 invariant 6, ADR 0004
- **Evidence:** `internal/qualification/gcp/gcp-bootstrap-inventory.md` §"Attempt 3" and
  §"Attempt 4"; `DONE/INFRA-042.md`

## Sol claim at stake

ADR 0003 invariant 6: "A failed or partially installed target is always
destructible. Lifecycle enforcement must never strand infrastructure."
`destruction_available` admits every phase except `Absent`.

## Verified provider / framework contract

The Terraform Kubernetes provider cannot delete a resource whose API does not
exist. A root whose state references CRD-backed resources whose CRDs were never
installed cannot be destroyed by that root. (This is a direct consequence of
Kubernetes API semantics, not a documented provider guarantee; the run is the
evidence.)

## The failure (Attempt 3)

Attempt 3's platform install failed at `gke-gcloud-auth-plugin`, so the CRDs were
never installed, but the platform root's state still referenced CRD-backed
resources. `sol cloud destroy` then ran `gcp-destroy-prepare` (ok),
`PreparingDestroy`, the reconciliation apply (ok), and `platform-destroy`
**failed** with `API did not recognize GroupVersionKind from manifest (CRD may not
be installed)`; the cloud layer was removed only by the emergency path.

## The fix (#362, merged as INFRA-042)

Terraform's destroy is attempted first, in full, with its own ordering. Only when
it has actually failed does Sol consider which state entries cannot correspond to
an object, and the proof is the cluster's own discovery
(`kubectl api-resources --verbs=delete`), deliberately narrow:

- only `kubernetes_manifest`, whose stored manifest states its kind verbatim
  (native `kubernetes_*` resources are deliberately not handled, because deriving
  their kind by convention can forget a resource that exists);
- only when the cluster does not serve that kind with `delete`.

Regression in `internal/ci/test_cloud_lifecycle_offline.sh` reproduces the
missing-CRD failure, asserts the recovery, retry and completed destroy, and pins
the opposite direction (CRD served → no `state rm`, destroy fails closed), both
mutation-tested.

## Evidence available

| Tier | Evidence |
|---|---|
| STATIC | the platform root declares CRD-backed resources; `destruction_available` admits `PlatformInstalling`/`CloudBootstrap`; the narrow recovery predicate in `cmd_cloud_tf.ml` |
| MECHANISM | the offline harness reproduces the missing-CRD failure and asserts both directions, mutation-tested |
| BEHAVIORAL | Attempt 3 is the live counterexample; **Attempt 4** then ran the documented destroy of a partially-installed platform to completion — `platform-destroy ok (80.0s)`, `terraform-destroy ok (342.6s)`, absence verified — "INFRA-042's scenario live, through the documented lifecycle, with no emergency cleanup" (GCP inventory, Attempt 4) |

## What is established

- The defect was real and reproduced on GCP (Attempt 3).
- The fix is merged, offline-tested in both directions, and mutation-tested.
- A partially-installed GCP platform has since been destroyed through the public
  lifecycle with no emergency cleanup (Attempt 4).

## What is NOT established

- Whether Attempt 4's platform state actually *required* the missing-CRD `state
  rm` recovery, or whether its install stopped before any CRD-backed resource was
  recorded (Attempt 4 stopped at `helm_release.cert_manager`'s post-install
  check, with cert-manager's six CRDs installed). The inventory's claim is
  behavioural for the broader scenario; the specific recovery path's live
  qualification is therefore not asserted here.
- Whether the same failure is reachable on AWS (never exercised with a
  CRD-missing platform state there).

## Impact

The third mechanism that reaches ADR 0004's "normal activity must not make a
target undeletable" now has a guard. `prevent_destroy`, provider deletion
defaults and a missing CRD are all covered; the first two by
`check_destroy_completeness.sh`, the third by #362.

## Derived engineering work

INFRA-042 is `DONE`. Out of scope and unchanged: the `gke-gcloud-auth-plugin`
prerequisite (fixed) and the service-networking peering abandonment (FND-0005).

## Reconciliation (2026-09-19)

Updated from `OPEN` after rebasing onto `origin/main`: #362 merged the fix and
Attempt 4 exercised the scenario. State is `FIXED_UNQUALIFIED` rather than
`QUALIFIED` because the specific recovery path — not the general
partial-install-destructible property — is what remains unobserved live.

## Supersession

None; the finding's conclusion is extended, not replaced.
