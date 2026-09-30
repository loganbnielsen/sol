---
id: INFRA-094
type: bug
severity: high
source: GCP qualification Attempt 15b (2026-09-27)
---

# INFRA-094 — converge a target whose creation the provider failed

**Depends on:** None.

**Reconciled with `DEC-057` (2026-09-29):** the destroy semantics this concerns
are now stated at product level — environment destroy must converge the target to
absence without constructing, and must not touch the durable installation. That
strengthens the constraint rather than answering the question here, which is how
to converge a target whose creation the provider failed. Non-construction stays
the invariant; `DEC-057` adds that installation resources are out of scope for
any resolution.

Attempt 15b: a zonal GCE stockout failed the cluster creation after Terraform had recorded
resources; the supported destroy then planned a **Replace** of `google_container_cluster.main` and
Sol correctly refused it (destroy must not construct). The destroy exited non-zero with the cluster
standing, and the target could not be converged to absence — see `FND-0065` for the verbatim
evidence and the run record
`internal/qualification/records/2026-09-27-gcp-attempt15b-provider-stockout-and-partial-create.md`.

## Decision Required

The answer is a decision about destroy semantics, not a patch, and it must not weaken the
no-construction invariant. `FND-0065` lists the options: distinguish "state describes a resource the
provider never finished creating" from "state describes a resource that exists but no longer matches
configuration"; a supported explicit unblock path; or documenting an emergency procedure as the
supported answer. Resolve that decision (in this ticket or a DEC) before any implementation.

## Blocked On

The decision above. This ticket is in `BACKLOG` on purpose and must not be picked up as actionable
until the decision is recorded.

## Non-goals

- Do not weaken the no-construction-during-destroy invariant.
- Do not add a silent forget path or automatic state surgery.
- Do not add zone fallback, retry or any provisioning-behaviour change: the stockout is
  provider-owned and transient.
