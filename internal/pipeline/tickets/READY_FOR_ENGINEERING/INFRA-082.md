---
id: INFRA-082
type: decision
severity: medium
title: What destroying a target means when the cloud root is already gone but the platform state is not
source: GCP Attempt 8's preserved stale platform state, via the INFRA-079 decision investigation
---

**Depends on:** None.

**Related:** FND-0058 / `INFRA-079` (the cause of the stale state, fixed), DEC-048 (the authority
rule this is deliberately *not* part of), FND-0055, DEC-045,
`internal/qualification/records/2026-09-25-gcp-attempt8.md`.

**Reconciled with `DEC-057` (2026-09-29):** the developer-experience contract fixes
the *scoping* rule this decision sits under — `sol cloud destroy <target>` removes
an environment and leaves the durable installation intact — but it does not answer
the question here, which is about a target whose provider resources and platform
state disagree. The decision stays open. `DEC-057` adds one constraint: whatever
this resolves must never reach installation-level resources.

## Context

Attempt 8's destroy was degraded by FND-0058, so the platform teardown was skipped and the cloud
root was then destroyed. The preserved platform Terraform state still holds 11 resources
(`sol/qual/gcp/us-central1/platform.tfstate/default.tfstate`) whose objects cannot exist: the cluster
that carried them is gone. Today a further `sol cloud destroy` does not examine the platform root at
all in that state — `Substrate_absent` returns `Cleanup_not_needed` because *"Terraform represents
nothing"* — so the stale state is inert, unreported, and self-heals only if the target is applied
again.

## Decision Required

Is that acceptable, or should the supported path be able to establish that the platform's objects
cannot exist and reconcile the state accordingly? The shape matters:

1. **Accept it.** Record that a target whose substrate is absent has no platform obligations, and
   that stale platform state is bookkeeping whose only consequence is a destroy postcondition that
   cannot be met (`INV-DESTROY-4`'s "both destroys return success"). Cheapest; leaves the state
   object as an artifact.
2. **Extend the existing "forget what provably cannot exist" recovery** (INFRA-042:
   `platform-destroy-forget-unserved` already forgets state entries for kinds the cluster
   demonstrably does not serve, reasoning *"the objects, not the objects' absence, is what Terraform
   cannot address"*) to the absent-substrate case, with the same rule that only a *provable*
   absence qualifies — never an unreadable one.
3. Something else, if the review finds a smaller honest shape.

## Explicit non-goals

No provider discovery, no adoption/import, no ownership reconstruction, no generic state-truth
layer. If the answer is 2, the result must still be an explicit, reported act with its own evidence
rule, and FND-0055's "UNKNOWN is not ABSENT" must hold.

## Acceptance criteria

- Whichever option is taken, the preserved Attempt 8 state is accounted for: either declared inert
  with the consequence named, or reconciled by the supported path with evidence.
- No `terraform state rm`/`import`/provider deletion outside the chosen mechanism; the preserved
  bundle stays as it is until then.

## Disposition (2026-10-03) — decision required

Smallest decision: accept stale platform state as inert bookkeeping with the unmet destroy postcondition documented, or extend the INFRA-042 "forget what provably cannot exist" rule to the absent-substrate case with an explicit evidence rule. Consequence: accepting leaves `INV-DESTROY-4` unmet; reconciling adds an explicit, reported state-truth mechanism.

Surfaced to the operator as a category-5 decision; not deferred. Moves to
`READY_FOR_ENGINEERING/` once the decision is recorded. See
`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`.


## Decision (2026-10-03) — reconcile provable absence

Operator decision: **Extend the existing INFRA-042 "forget what provably cannot
exist" rule to the absent-substrate and failed-create cases.**

Reconciliation is permitted only when provider absence is positively established
through the authoritative provider boundary. UNKNOWN — including authorization
failures, transport failures, malformed responses, or inability to inspect the
provider — must never be treated as ABSENT. The non-construction invariant is
preserved: reconciliation may remove stale Sol state but must never create
infrastructure to make destroy possible. Promoted to
`READY_FOR_ENGINEERING`.

## Reconciliation (2026-10-03, ADR 0005)

ADR 0005 bounds this work: the reconciliation it authorises covers state Sol
owns (its own platform root), and it never becomes a licence to discover,
import or mutate resources the user manages outside Sol.
