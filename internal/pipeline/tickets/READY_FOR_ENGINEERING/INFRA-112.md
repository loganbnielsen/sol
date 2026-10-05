---
id: INFRA-112
type: infra
severity: medium
source: Stream A validation-workflow investigation, 2026-10-05
title: Reuse canonical check results for an identical committed tree instead of re-running pre-push
---

**Depends on:** None.

## The gap

An actor implements a ticket, runs checks while working, commits, and then the pre-push hook re-runs the
canonical suite from the beginning on the same committed tree. Observed repeatedly while implementing
INFRA-109, DEC-066 and the filings around them: pre-push ran 113s, 156s and 170s of members that had
already passed minutes earlier on the same tree. The only escape was to run the remaining members by hand
and then bypass the hook — which must not be the workflow, because a hand-reconstructed gate and a
bypassed hook are both weaker than the canonical one, and neither is evidence.

## Desired invariants

1. **Evidence binds to content.** A reusable result is keyed by the exact committed tree
   (`git rev-parse HEAD^{tree}`), the identity of the validator (the canonical runner's own content hash)
   and the toolchain it ran under. A branch name, commit subject or PR number may never appear in the key.
2. **Changed content invalidates.** Any change to the tree — amended commit, extra staged file, edited
   tracked file — is a miss, with a test proving it.
3. **Only the canonical runner writes.** A verdict counts only if `internal/ci/run_fast_checks.sh`
   produced it for that tree; members run individually by hand never add up to the suite.
4. **The pre-push guarantee is unchanged.** Pre-push still ensures the pushed tree passed the full suite
   before it leaves. Reuse removes duplicated work, never the guarantee.
5. **CI stays independent.** CI never consults the local store and re-validates the pushed commit itself.
6. **Local, per-clone, never committed.** The store lives under the git directory, so worktrees of one
   clone share it and no repository artifact is created — a results file inside the tree would invalidate
   the tree it describes.
7. **Visible when used.** A reused verdict reports which verdict was reused, for which tree, when it was
   produced, and how to force a re-run. Silent reuse is indistinguishable from a skipped gate.
8. **Failure is never cached.** A failed or interrupted run records nothing and invalidates any earlier
   pass for that tree.

## Shape of the change

`run_fast_checks.sh` records a verdict on success and consults the store on start, exiting immediately
with an explanation when the same tree already holds a valid one, plus a force re-run. The pre-push hook
from INFRA-109 keeps evaluating the pushed tree and inherits the reuse, so a tree validated minutes
earlier in the same clone is not paid for twice.

## Acceptance criteria

- A tree validated once does not re-run its members on pre-push; the output names the reused verdict, its
  tree and its timestamp.
- Every invalidation case above has a test; a hand-run member is not reused; an interrupted run is not a pass.
- CI output shows an independent run for the same commit.
- `git status` and the committed tree gain no artifact.
- The INFRA-109 regression test passes unchanged; a new test covers reuse and invalidation.
- Example impact: none; developer tooling. Language-parity impact: none.

## Related, and why this is separate

- **INFRA-109** changes *what* pre-push evaluates (the pushed tree, not the working tree). This changes
  *whether the same work is done twice* for one tree. Same hook, different question; the cache must key on
  the tree the hook evaluates, which INFRA-109 makes explicit.
- **INFRA-110** makes the checks able to grade a fresh worktree; a miss there costs a full build, which is
  where reuse pays most.
- No existing ticket covers reuse. FRIC-014 and REFAC-153 are done and address other friction.

## One guidance correction, small and independent

`AGENTS.md` says the pre-push hook runs "every fast `internal/ci/` guard, in parallel". The implementation
is **serial across its stages**: `run_fast_checks.sh` builds, then unit tests, then the offline cloud
lifecycle suite, then the context-bound guards, then the verification classes — and it states why the
dune-based stages must be serial ("serial: they hold dune's build lock"). The implementation is right; the
guidance overstates it. Say that guard members run under the class runner while the dune-lock stages are
serial, or drop "in parallel".
