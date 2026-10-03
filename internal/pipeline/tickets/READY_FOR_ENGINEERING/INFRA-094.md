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

## Disposition (2026-10-03) — decision required

Smallest decision: how the supported destroy converges a target whose provider-create failed mid-apply — distinguish "never finished creating" from "exists but diverged", a supported explicit unblock path, or a documented emergency procedure. Consequence: must not weaken no-construction-during-destroy; zone fallback/retry stay out of scope.

Surfaced to the operator as a category-5 decision; not deferred. Moves to
`READY_FOR_ENGINEERING/` once the decision is recorded. See
`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`.


## Decision (2026-10-03) — reconcile provable absence

Operator decision (the same rule as INFRA-082): **extend the INFRA-042 "forget
what provably cannot exist" rule to the provider-failed-create case.**
Reconciliation is permitted only when provider absence is positively established
through the authoritative provider boundary; UNKNOWN — authorization, transport,
malformed response, or inability to inspect — is never ABSENT. Distinguish
"state describes a resource the provider never finished creating" from "state
describes a resource that exists but diverged", and keep no-construction as the
invariant: reconciliation may remove stale state but never create infrastructure.
Promoted to `READY_FOR_ENGINEERING`.

## Reconciliation (2026-10-03, ADR 0005)

ADR 0005 bounds this work the same way as INFRA-082: reconciliation covers state
Sol owns, and it never becomes a licence to discover, import or mutate resources
the user manages outside Sol.


## Sequencing (2026-10-03)

This ticket reuses the provable-absence reconciliation INFRA-082 introduces (the
INFRA-042 extension); it is not an independent mechanism. INFRA-082 lands first.
They form one reconciliation unit across two tickets.
