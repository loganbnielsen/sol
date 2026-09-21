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
