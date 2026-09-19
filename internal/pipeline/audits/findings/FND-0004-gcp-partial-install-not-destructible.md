# FND-0004 — A partially installed GCP platform is not destructible through the lifecycle

- **Classification:** `VERIFIED_DEFECT`
- **State:** `OPEN` (INFRA-042 not implemented)
- **First identified:** 2026-09-19 (GCP qualification Attempt 3)
- **Last verified:** 2026-09-19, `main @ 7ea2ef43`
- **Provider:** GCP / GKE
- **Derived ticket:** **INFRA-042** (`internal/pipeline/tickets/READY_FOR_ENGINEERING/INFRA-042.md`)
- **Related invariant:** `INV-DESTROY-1`
- **Related decisions:** ADR 0003 invariant 6, ADR 0004
- **Evidence:** `docs/qualification/gcp-bootstrap-inventory.md` §"Attempt 3"

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

## Current implementation evidence

- The GCP platform root (`cli/platform/infra/base-gcp`, module `../base`)
  contains `kubernetes_manifest` ClusterIssuers and other CRD-backed resources.
- Attempt 3's platform install failed at `gke-gcloud-auth-plugin`, so the CRDs
  were never installed, but the platform root's state still referenced those
  resources.
- `sol cloud destroy` then ran `gcp-destroy-prepare` (ok), `PreparingDestroy`,
  the reconciliation apply (ok), and `platform-destroy` **failed** with
  `API did not recognize GroupVersionKind from manifest (CRD may not be
  installed)`; the cloud layer was removed by the emergency path.

## Evidence available

| Tier | Evidence |
|---|---|
| STATIC | the platform root declares CRD-backed resources; `destruction_available` admits `PlatformInstalling`/`CloudBootstrap` |
| MECHANISM | the offline lifecycle harness asserts a partially-installed target is destructible — but it asserts the *phase model*, not provider behaviour with a missing CRD |
| BEHAVIORAL | Attempt 3 is a live counterexample on GCP: the lifecycle could not complete the destroy |

## What is established

On AWS the abort edge works (Run 5 Attempt 1 destroyed a target whose platform
install failed). On GCP the phase model admits destruction but the destroy
operation cannot complete when the platform root's state references resources
whose CRDs do not exist.

## What is NOT established

- Whether the same failure is reachable on AWS (never exercised with a
  CRD-missing platform state there).
- The right shape of the fix (drop-from-state when the CRD's absence is
  established from the cluster; or split CRD-installing components into a
  prerequisite root) — INFRA-042 leaves this open.

## Impact

Three mechanisms now reach ADR 0004's "normal activity must not make a target
undeletable": `prevent_destroy`, a provider deletion default, and a resource
whose API does not exist. The first two are guarded; the third is the open
counterexample. A failed install is the state a target is most likely to be in.

## Derived engineering work

**INFRA-042** (high). Out of scope: the `gke-gcloud-auth-plugin` prerequisite
(fixed) and the service-networking peering abandonment (FND-0005).

## Supersession

None.
