
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
