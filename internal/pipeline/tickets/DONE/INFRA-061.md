
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

## Remaining hardening of the principal check (identified, not yet applied)

The parser on this branch handles the EKS shape (arrays under `status.userInfo.extra`, else
a flat string), prefers `canonicalArn`, compares role names, and returns `Error` -- which
the caller maps to `Undetermined` -- rather than a default. Five further hardenings were
identified and are **not yet applied**; an attempt was reverted rather than land a
half-restructured module at the end of the session:

1. **Compare (account, role), not role alone.** The same role name in a different account
   is a different principal, and the current comparison would call it the same.
2. **Normalise role paths.** `canonicalArn` drops the path (SSO roles are the common case)
   while `arn` may not, so the two spellings of the same role must compare equal.
3. **Reject ambiguous arrays.** An empty array, a multi-element array, or a non-string
   should be an `Error`, not an occasion to take the first element -- that is a default in
   disguise.
4. **Discover the ARNs by shape, not by key name.** The documented keys are `arn` and
   `canonicalArn`, but naming can differ between access entries and aws-auth, and a parser
   pinned to a recalled key list fails closed on a cluster that spells it differently.
5. **Keep parse failure distinct from denial**, with a regression case tying a parse
   `Error` to `Undetermined` and never to `Still_elevated` or `Deescalated`.

**Correction (2026-09-21).** An earlier version of this note claimed every failure mode
above fails closed. That was an overclaim, and specifically wrong about one of them:
comparing an extracted *role name* fails **open**, because the same role name in another
account, or behind a different role path, looks like the same principal -- and a different
principal being denied afterwards would read as `Deescalated`. The comparison has been
changed to the **full canonical ARN**, account and path included, whose worst case is a
false mismatch (safe but noisy), and it is now a tested lib function (`principal_matches`).

The honest position, mode by mode -- *verified* means a test fails when the behaviour is
wrong, not that it was read and believed:

| Failure mode | Status |
|---|---|
| parse failure / non-JSON / no ARN at all -> `Undetermined`, on **both** the window control and the post-de-escalation probe | **verified closed** (mutant: mapping a probe failure to `Still_elevated` fails the test) |
| same role name in a different account -> not the same principal | **verified closed** (mutant: comparing the final segment fails the test) |
| same role behind a different role path -> not the same principal | **verified closed** (same mutant) |
| a session-carrying `arn` cannot confirm a role ARN | **verified closed** (fixture) |
| a **multi-entry** array -> the ambiguity is *reported* | **verified closed** (the parser refuses it; a mutant that takes the first element fails the test) |
| a value that is neither a string nor a single-element array -> `Undetermined` | **verified closed** (same test) |
| an **unknown shape** (keys named differently, no ARN discoverable) -> `Undetermined` | **verified closed as a mapping** -- and *not* a validation of the EKS shape. The claim is that unknown shapes do not proceed, checked against the fixtures; whether the fixtures match what EKS emits is what the capture below settles, not this row. |
| account+role **precision** (no false mismatches) | **not claimed**: false mismatches are possible and land in `Undetermined`. Safe, but noisy until hardening 1 and 2 land. |

That is why the epoch may proceed before this lands: the ways it can be wrong are noisy,
not permissive. And it is why the live capture (see the run-record template) is the step
that settles the real shape -- the fixtures encode a shape recalled from the API, not
captured from EKS.

## Harness coverage canary (applied 2026-09-21)

`internal/ci/test_cloud_lifecycle_offline.sh` now fails if it never enters the
bootstrap-access-removal phase, so the transition coverage cannot quietly go absent while
every assertion still passes. Verified by breaking the phase pattern: the canary fails.
Worth recording that the first reading here was wrong -- a grep of the harness's *stdout*
suggested the phase never ran, when the per-scenario logs are where the output goes. The
canary is what settled it, which is the argument for having one.

## Early shape gate (applied 2026-09-21)

The fixtures encode a shape recalled from the API. The only thing that compares that
against a real answer is the cluster itself, and a template step is the kind of thing that
gets skipped when a bootstrap is already running and the environment is costing money. So
it is a gate instead:

As soon as the cluster is reachable -- after the cloud apply, before the platform install,
which is the expensive part -- Sol runs `kubectl auth whoami -o json` once as the
provisioner and **fails the run** if the parser cannot identify a principal, printing the
raw response for the run record to diff against the fixture shapes. A transient failure to
reach the cluster is not a shape mismatch: it is reported, and the verification itself
stays fail-closed.

The gate retries with backoff and then **fails** rather than warning: a fresh EKS endpoint
is briefly unable to authenticate its own principal, but once the retry window expires, the
gate not having run is a failure rather than a pass -- otherwise the run proceeds into the
expensive install with the shape unchecked and discovers the mismatch at de-escalation. It
also asserts that the principal is **the expected provisioner** (a leftover credential of
another identity must not pass a shape check) and that the identity came from
**`canonicalArn`**, the field the comparison depends on.

Verified falsifiable, end to end: with the parser mutated to reject every shape, the offline
lifecycle harness fails the run; with the emulated cluster answering without `canonicalArn`,
it fails the run; restored, it passes. The harness asserts the gate reported a parsed
response, so the check cannot quietly go absent. A green harness is still not shape
validation -- it emits the recalled shape -- which is what the capture is for.

This means the epoch cannot spend an hour on a bootstrap whose de-escalation verification
was never going to succeed -- the mismatch is found in the first minutes, while the target
is still destructible.

## If the first de-escalation returns Undetermined for a principal mismatch

Check the two captured ARNs before concluding the cluster misbehaved. The strict full-ARN
comparison can produce false mismatches -- `canonicalArn` dropping a role path while `arn`
keeps it is the known case -- and a mismatch lands in `Undetermined`, which is fail-closed
but noisy. The gate's capture, plus the post-de-escalation probe's `identity source`, say
which field each side came from. Reading those two before blaming the cluster is the
difference between finding a real defect and chasing a false one.
