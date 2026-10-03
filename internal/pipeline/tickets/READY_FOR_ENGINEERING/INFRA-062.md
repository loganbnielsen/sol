---
id: INFRA-062
type: decision
severity: medium
title: Decide how a qualification run re-establishes a workload fixture
source: audit finding FND-0022 — DEC-039
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0022-fixture-reset-has-no-sol-mechanism.md`
**Contract:** DEC-039

## Problem

A redeploy of the revision Sol already has recorded does not reset a degraded fixture:
an unchanged Deployment spec means no rollout, so the failing pods stay. Verified
live — `generation` stayed 1, the same pods with the same creation timestamps, still
0/2 ready, `sol status` still `DEGRADED`, while the deploy reported success and advanced
the release record.

That is intended: B2 qualifies the opposite property (an identical repeat deploy must
not restart workloads). The gap is that the qualification procedure assumes a reset is
expressible, and it is not.

## Decision needed

Choose and document one, with the trade-offs in the finding:

1. **New revision** — resets the pods, changes the fixture's release identity.
2. **An explicit Sol restart/reset capability** — a product change that must not weaken
   B2's idempotence contract.
3. **Fixture teardown and recreate** — the cleanest new epoch, largest change.

Explicitly rejected: ad-hoc `kubectl delete pod`, which is undocumented and hides the
missing capability.

## Acceptance criteria

1. The chosen mechanism is written into the run procedure, including what constitutes a
   new evidence epoch and what the reset does to release identity.
2. It does not weaken B2 (`no workload restarts, pointer unchanged` on an identical
   redeploy).
3. If a Sol capability is chosen, it is qualified live against a deliberately degraded
   fixture and the resulting evidence is recorded as the new epoch.
4. If fixture recreate is chosen, the procedure says how the failure evidence of the
   previous epoch is preserved before teardown.

## Out of scope

Repairing the current `notify-worker`; that decision belongs with this one.


## Decision (2026-10-03) — teardown and recreate the fixture

Resolved on the existing contracts, not by smallest-change:

- **DEC-039** places fixture-lifecycle *mechanics* with the qualification
  harness, never with a production identity. A reset is harness mechanics.
- The qualification requirement is a clean evidence epoch against the **same
  artefact**, so the epoch after a reset is comparable to the one that recorded
  the failure.
- **B2** (an identical redeploy restarts nothing) must not be weakened.

**Option 3 — fixture teardown and recreate** follows: it preserves the artefact
under test, adds no product surface, and does not touch B2.

**Option 1 (new revision)** is rejected: it changes the artefact, so the new
epoch would not be comparable to the failure epoch (FND-0022's own objection).

**Option 2 (an explicit Sol restart/reset capability)** is a real product
capability but is not required by the qualification contract and is not asked for
by B2; it remains a **separate, undecided product question** and is deliberately
not created here.

Implement by writing the reset into
`internal/qualification/aws/aws-run-procedure.md`: what declares a new evidence
epoch, how the previous epoch's failure evidence is preserved before teardown,
and that the recreated fixture uses the same revision. This ticket stays
`READY_FOR_ENGINEERING`.
