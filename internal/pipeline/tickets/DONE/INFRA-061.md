
## Landed (2026-09-21)

The invariant is implemented where the violation was: `De-escalate` now verifies the
effective authorization surface after removing the bootstrap access, and `Ready` is not
announced until it passes. `sol_cli_cloud_lifecycle.deescalation_verdict` decides from
the authorizer's answers to the capabilities only the bootstrap authority held
(`create clusterroles`, `create clusterrolebindings`, `escalate clusterroles`), probed
as the steady-state platform identity; anything still permitted, or no answer at all,
fails the phase closed (`Undetermined` is never de-escalated).

The order at the call site was also wrong in the same direction and is fixed: `Ready`
used to be announced **before** the de-escalation apply, so the claim preceded its
evidence. It now follows a verified de-escalation.

Coverage: `verified de-escalation (DEC-040)` in `test_cloud_lifecycle.ml`, three cases
— all refused → de-escalated; one still permitted → `Still_elevated` naming it; no probe
answered → `Undetermined`. Mutation-verified: collapsing the verdict so a permitted
capability reads as de-escalated (the FND-0021 shape) fails the test.

Still open in this ticket: the qualification transport's establishment must follow the
destroy-then-establish sequence (DEC-040, `FND-0020`), and the `De-escalate` phase has
not yet been exercised live against a cluster where de-escalation was actually pending.

## Positive control (2026-09-21): a denial is not a transition

The first implementation proved only *"at time B this principal cannot exercise bootstrap
authority"*. That is not the security claim. The claim is a transition of the same
principal and the same capabilities:

```
same principal P, same capability set C

  bootstrap window:   P can do C        <- must be observed, not assumed
        |  de-escalate
        v
  steady state:       P cannot do C     <- observed
```

Without the first observation, a broken credential, a wrong principal, a bad auth path or
a capability that was never granted all produce the identical final denial -- and this run
has met variants of every one of those.

**Contract.** De-escalation evidence must establish a transition:

1. identify principal P whose bootstrap elevation is being exercised;
2. **during the bootstrap window**, ask the effective Kubernetes authorizer whether P
   possesses the bootstrap-only capability set, and require those capabilities to be
   observed *permitted*;
3. de-escalate;
4. interrogate the effective authorizer again as the same P for the same capability set,
   and require them *denied* before `Ready`;
5. if the positive control cannot obtain evidence, the verification is `Undetermined` and
   **`Ready` is not announced**; a principal mismatch on either side invalidates the
   transition evidence.

Authorization queries are preferred over test mutations: asking the authorizer whether P
may `create clusterroles` observes the capability on the same path that enforces it,
without adding a mutation whose only purpose is to prove authority.

**Regression coverage** (`verified de-escalation is a transition (DEC-040)`), all
mutation-verified as a valid mutant (mutated build succeeds, then the test fails):

| Case | Verdict |
|---|---|
| capability never observed granted | `Undetermined` — nothing was removed |
| a different principal answered after | `Undetermined` — the transition is unproven |
| measurement failure before or after | `Undetermined` |
| same principal, permitted before and denied after | `Deescalated` |
| same principal, still permitted after | `Still_elevated` |
