# FND-0030 — Destroy is unavailable for an interrupted target, because PreparingDestroy reconciles constructively first

- **Classification:** `VERIFIED_DEFECT` — the behaviour is observed; the *mechanism* is an
  open design question
- **State:** `OPEN` — needs a design decision before a fix; not derived from `INFRA-067`
- **First identified:** 2026-09-23 (GCP Attempt 6)
- **Last verified:** 2026-09-23, `main @ 835841a8`
- **Provider:** GCP observed (GKE); the shape is in shared lifecycle code — see "NOT established"
- **Derived ticket:** none yet — the acceptance criterion is behavioural and the mechanism is open
- **Related invariant:** **ADR 0003 invariant 6** — destruction is an abort edge available
  from every phase, including a half-built one
- **Related:** `INFRA-067` (the same family, a different manifestation), `FND-0028`,
  `docs/qualification/2026-09-23-gcp-attempt6.md`

## The invariant this violates

ADR 0003 invariant 6 states that destruction is an abort edge available from **every**
phase that can hold infrastructure, including a half-built one. The implication that
matters here: for a partially created target, **absence is progress toward the destroy
postcondition.** A destroy path must never require reality to first look like a
successfully applied target.

## The observed failure

An apply was interrupted after the provider had created resources but before Terraform's
state recorded all of them (the GKE cluster existed and was absent from state). Then:

| Step | Result |
|---|---|
| `sol cloud destroy … --apply` | `gcp-destroy-prepare` runs a **constructive** targeted apply (`-target=google_container_cluster.main`) to lower deletion guards |
| that apply | **fails**: `googleapi: Error 409: Already exists` — Terraform plans to *create* the cluster that exists but is not in state |
| the destroy | aborts before destroying anything |

So the only supported path to zero refused to run because the target was half-built — the
state in which it is most needed. Recovery required, in order: an attempted
`terraform import` (which hung on the cluster, then `PROVISIONING`), direct provider
deletion of Cloud SQL and of the cluster (refused until the orphaned GKE creation
operation cleared, then driven through a retry loop), removal of three stale SQL entries
from state, and a final `terraform destroy` (11 resources). None of that is a product
contract, and the user-facing consequence is the one the cost rule exists to prevent.

## Why this is separate from INFRA-067

`INFRA-067` fixed destruction being refused by **install-time validation**
(`PreparingDestroy` evaluating a capability guarantee). This finding is about
**reconciliation semantics**: the destroy path performs constructive reconciliation
before destructive reconciliation, so a divergence between state and provider reality
blocks teardown. Both are instances of one architectural statement — *a destruction path
must not depend on logic whose purpose is creation* — but they are different mechanisms
with different fixes, and `INFRA-067`'s fix remains correct on its own.

## Acceptance criterion (behavioural, deliberately not prescriptive)

> Given an apply interrupted after provider resources have been created but before the
> target is fully represented or reconciled, Sol provides a supported path to converge
> target-owned infrastructure toward **absence** without first creating missing target
> resources.

Whether that is achieved by bypassing constructive preparation, by refreshing/adopting
resources, by invoking Terraform differently, or by an explicit recovery operation is a
design decision. Today's manual procedure **must not** be encoded as the product contract.

## What is NOT established

- The mechanism, and therefore whether it is a phase-boundary change or a recovery
  operation (needs a decision; `INFRA-067`'s context distinction is a precedent for the
  former).
- Whether AWS is affected: the destructive preparation is provider-shaped
  (`google_container_cluster` here), but the *constructive reconciliation before destroy*
  is a shared-lifecycle property.
- The complete set of divergence shapes. One is observed (resource created, absent from
  state). Others — resource deleted out of band, partially recorded attributes — were not
  exercised.

## Supersession

None.
