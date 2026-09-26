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
