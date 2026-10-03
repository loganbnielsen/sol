---
id: INFRA-062
type: decision
severity: medium
title: Decide how a qualification run re-establishes a workload fixture
source: audit finding FND-0022 — DEC-039
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0022-fixture-reset-has-no-sol-mechanism.md`
**Contract:** DEC-039

**Premise (verified 2026-10-03):** the decision below is resolved and applied, but its
implementation was absent. Checked:
`git show origin/main:internal/qualification/aws/aws-run-procedure.md | rg -ni 'fixture|re-establish'`
— one match, the HARDEN-003 line about re-establishing *connections*; the word "fixture"
did not appear in the procedure at all, and the decision's own instruction ("implement by
writing the reset into `internal/qualification/aws/aws-run-procedure.md`") had no
corresponding section.

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
and that the recreated fixture uses the same revision.

## Completion (2026-10-03)

Implemented as the procedure section § *Re-establishing a workload fixture (INFRA-062 /
FND-0022, decided 2026-10-03)* in `internal/qualification/aws/aws-run-procedure.md`, with
a pointer from step `7` (`B3`–`B7`), and the failure-epoch/`Ready` epoch boundary
recorded in the run record's model (run 8's `# EVIDENCE BOUNDARY` section).

**The mechanism, and the one judgement it required.** The reset is a teardown and
recreate driven through Sol's own surface: `sol cloud destroy <target> --apply` to
verified `Absent`, then the procedure from step 1 with the **same `--image-ref`
digests**. A namespace-scoped teardown is not expressible and was not used: DEC-039's
transport grant is deliberately non-mutating (`get`/`list`/`portforward` only), and the
provisioner — the only identity that owns infrastructure mutation — mutates only through
Sol's lifecycle, so `kubectl delete namespace` would have required widening an identity
or an out-of-band mutation. That is why "fixture teardown" resolves to the target-level
Sol teardown rather than FND-0022's phrase "of the fixture namespace": it is the only
teardown Sol can perform, and it preserves the artefact under test (the digests) while
adding no product surface.

**Acceptance criteria.** (1) The new evidence epoch is written down: it begins at the
recreated target's `Ready` with the workload redeployed from the same digests, and the
record names the boundary and why the epochs are compared by artefact rather than by
release identity. (2) B2 is untouched — the procedure states the identical repeat deploy
still asserts no workload restarts and an unchanged pointer, and the reset adds no Sol
capability. (3) Not applicable: no Sol capability was chosen (option 2 stays an undecided
product question). (4) The failure evidence to freeze before teardown is enumerated (pod
table with creation timestamps, probe text, consumer-group view, release record), with
run 8's evidence-boundary section as the model.

**Demo / example coverage:** none applies — this is an internal qualification procedure,
not a change to what an app author does.

**Language parity (DEC-022):** no impact — harness/qualification mechanics, not a
framework convention or an application-facing capability.

**Remaining limitation:** the procedure is a procedure; the reset has not been executed
end to end. Its live exercise is part of `HARDEN-007` (AWS run 9), which is
operator-gated.
