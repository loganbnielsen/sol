---
id: INFRA-061
type: bug
severity: high
title: An EKS access-policy disassociation is reported as complete while the authorizer still honours it
source: audit finding FND-0021
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0021-disassociated-access-policy-remained-effective.md`

---

## START HERE -- what the epoch is blocked on

**Code scope completed 2026-09-21 on the corrective branch.** The ticket had been moved to
`DONE` with this checklist still open; a corrective PR (not a reopen) lands the remaining
fail-open and wrong-end-state items:

- [x] **A. Window on failure**: `verify_whoami_shape` and the bootstrap-window control run
      an `~on_error` cleanup before their terminal `lifecycle_error`, so a gate or control
      failure removes the bootstrap access. The offline harness injects a persistent gate
      failure and asserts the removal apply ran (`provisioner_bootstrap_admin=false`) and
      `bootstrap-window` reads `false`; dropping the cleanup from the mutant makes it fail.
- [x] **B. `can-i` tri-state**: `capability_answer = Permitted | Denied | Indeterminate`
      replaces the `(string * bool)` probe list, and the classifier is a pure lib function
      over kubectl's exit code and **stdout** (`yes`/`no`, tolerating a `no - reason`
      suffix; a token/exit mismatch is indeterminate). A transport or token failure is
      `Indeterminate`, the verdict is `Undetermined`, and it can never produce
      `Deescalated`. Unit-tested directly and mutation-verified in the harness.
- [x] **Control strictness**: the window control refuses a window containing an
      *indeterminate* probe even when another capability is permitted, so the run fails
      before the platform install instead of at de-escalation. A harness scenario
      (`CAN_I_INDETERMINATE_WHEN_OPEN`) pins it; a control that accepts "any permitted"
      reaches the install and fails the scenario.
- [x] **Destroy path**: `sol cloud destroy` revokes the bootstrap access too, so it
      observes the window and checks the effective surface afterwards. That check is
      **advisory**, a deliberate decision, and it does **not** mean the destroy path
      "verifies de-escalation" the way the install path does. DEC-040's first acceptance
      criterion -- "every path that revokes privileged access verifies the effective
      surface *before declaring the revocation complete*, and fails closed if it cannot"
      -- is satisfied in that operational sense: a destroy never declares a revocation
      complete, it removes the substrate, and its terminal proof is the verified absence
      of that substrate, which is stronger than the effective-surface probe. The check is
      deliberately not a gate: a probe that can fail must not block teardown (ADR 0003
      invariant 6) or strand billable infrastructure (HARDEN-004's cost rule), and the
      observation runs as the *provisioner* role while the teardown uses the
      *cluster-access* role, so a fatal probe would let a broken provisioner trust abort a
      teardown that would otherwise succeed. The harness scenario therefore asserts an
      indeterminate post-removal probe is **reported** and teardown completes.
- [x] **The offline harness green on the head**, including the new cases.

Two facts are deliberately *not* checklist items here, because neither is code this ticket
owns:

- **Full-suite green** is recorded by this PR's CI. The head now carries code, so a
  `test` job that ran to completion with no code commit between it and the head is the
  readable record (the rule the ticket itself added).
- **The first live capture** is a HARDEN-002 run step, not a code item: it belongs in the
  next run record's capture section, where the parser meets the real authorizer response.
  This branch narrows what that capture has to confirm; it does not replace it.

**A red that was real, then fixed, and is now self-diagnosing.** The offline harness once
failed at a **stub syntax check** and named the line:

```
the generated aws stub is not valid shell:
/tmp/.../bin/aws: line 74: syntax error near unexpected token `"$1 $2"'
/tmp/.../bin/aws: line 74: `[ "$1 $2" = "eks update-kubeconfig" ] || exit 90'
```

So the `sts assume-role` case was moved out of its `case ... esac` and the block was split. The
harness now runs `bash -n` over every generated stub before anything else, because a syntax
error there used to surface as a plausible-looking product failure -- an "eks update-kubeconfig
failed" message -- and took several rounds to trace back. Same pattern as the coverage canary:
a cheap assertion that fails loudly, so this harness cannot fail for a reason that looks like a
bug in sol. The terraform, kubectl and gcloud stubs parse cleanly.

**The fix is one coherent edit**: rewrite that region of the aws stub as a single block -- the
`sts assume-role` case and its `esac`, then the eks-only guard, then the `--role-arn` case and
its `esac` -- rather than moving arms or deleting braces by text. Several attempts at the text
route each left a stray or missing `esac`; the syntax check caught every one of them, which is
the argument for having it.

**Resolved.** The splice landed by script (three preconditions gating the write, condition 3
having caught a mistake before it could apply), the harness is green, and the discriminator
scenario is load-bearing: ignoring the identity check fails it with *"a refusal with an
unassumable role was accepted as de-escalation."*

**But the claim is narrower than "no mismatch surfaced".** Precisely: **no mismatch surfaced in
the scenarios that exist.** The stub answers instantly and coherently, and the `WHOAMI_REFUSE`
scenario exercises only the **negative** path -- an unassumable role giving `Undetermined`. The
positive pairing (refused **and** assumable, which must reach `Deescalated`) is still unit-only,
so the end-to-end refusal branch has never run against the stub at all. That is fine to defer,
and the paired control is what closes it.

**The heredoc check has one blind spot, accepted.** Counting markers (8 opened, 8 closed) catches
a swallowed terminator, which is the false-green path it was added for. It does not catch a
generator whose body was truncated but still ends with a correct `EOF`, nor an arm moved to the
wrong place inside an otherwise valid stub. `bash -n` plus the discriminator mutant cover the
second case for the `sts` arm; nothing covers it for the other arms, but the existing scenarios
exercise them. Low risk, and deliberately no extra check.

**Where the epoch stands -- three blockers, in order of consequence:**

1. **A, window left open on failure.** Can leave elevated access applied on a cluster the run
   has just decided it cannot verify. Design-shaped.
2. **B, `can-i` tri-state.** Can produce a wrong `Deescalated`. Design-shaped, and it needs its
   own mutant.
3. **Full-suite green on the head**, with the path named. Pending on CI.

**Head of record:** `290f685a` -- local HEAD, `origin` head and the PR head all agree, so the
run in flight is for the current head and not an earlier one.

---


## Problem

`aws eks disassociate-access-policy` was accepted, `describe-access-entry` reports
`accessPolicies: null`, and the cluster's authorizer still granted the full
`AmazonEKSClusterAdminPolicy` for more than five minutes — verified by reading an
object the declared grant does not cover, from a principal confirmed at the time of
the read. Deleting the access entry propagated in under 45 seconds, so the policy
disassociation path specifically is the one that did not.

## Why it matters

Anything that asserts de-escalation from the API's own report — a bootstrap that
revokes its installation authority, a qualification harness closing a window, an
audit checking that a temporary grant is gone — inherits a false confirmation. The
platform's claim ("this identity now has only these permissions") does not hold at
the moment it is made.

## Acceptance criteria

1. Reproduce deliberately: associate a policy, disassociate, and measure the
   *effective* surface over time (a real authorized call, not `can-i` alone, and not
   the API's description).
2. Establish whether it is a propagation delay (with a bound) or a persistent
   divergence. Record the answer.
3. Every path that revokes privileged access verifies the **effective** surface
   before declaring the revocation complete. In this repository that means at least
   Sol's own de-escalation (`De-escalate` in the lifecycle phases) and the
   qualification harness.
4. If a bound exists, document it where de-escalation is claimed; if it diverges,
   treat the API's report as untrusted for this operation and say so.

## Out of scope

Changing ADR 0003's authority model; the model is right, its confirmation is what
turned out to be unreliable.
## Landed (2026-09-21)

The invariant is implemented where the violation was: `De-escalate` now verifies the
effective authorization surface after removing the bootstrap access, and `Ready` is not
announced until it passes. `sol_cli_cloud_lifecycle.deescalation_verdict` decides from
the authorizer's answers to the capabilities only the bootstrap authority held
(`create clusterroles`, `create clusterrolebindings`, `escalate clusterroles`), probed
as the provisioner whose elevation the run manages; anything still permitted, or no answer at all,
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

## Principal-check hardening (state reconciled 2026-09-21)

The parser handles the EKS shape (arrays under `status.userInfo.extra`, else a flat
string), prefers `canonicalArn`, and returns `Error` -- which the caller maps to
`Undetermined` -- rather than a default. Five hardenings were identified; the correction
below records how the comparison changed. Their **current** state:

- items 1 and 2 (account+role precision, role-path normalisation) are applied: the
  comparison is the **full canonical ARN**, and the expected side is normalised by
  `normalize_role_arn` so a role with a path does not produce a false mismatch;
- item 3 (reject ambiguous arrays) and item 5 (parse failure distinct from denial) are
  applied and mutant-verified;
- item 4 (discover the ARNs by shape rather than the recalled key names) is **deliberately
  still not applied**: it is what the first live capture settles, and building it against
  the same recalled keys would only move the assumption.

The original list is kept for context:

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

## Outstanding from review (2026-09-21), recorded so the next session starts here

**1. A failed gate or control leaves the bootstrap window open — NOT FIXED, highest priority.**
`verify_whoami_shape` and `observe_bootstrap_window` call `lifecycle_error` directly, while the
surrounding failure paths pass `~on_error:cleanup_bootstrap_access`. A minute-one failure
therefore exits with `provisioner_bootstrap_admin=true` still applied on a cluster the run has
just decided it cannot verify — the wrong end state for a least-privilege change.

The fix is a local `fail message = on_error (); lifecycle_error message` helper in each
function, with `~on_error:cleanup_bootstrap_access` passed at both call sites (the binding is
already in scope above them). An attempt at this was reverted rather than left half-applied;
the remaining work is mechanical. Needs a harness case where the gate fails persistently and
the log shows the removal apply ran (`bootstrap-window` reads `false`).

**2. The STS stub branch was dead code — FIXED.** In the aws stub,
`[ "$1 $2" = "eks update-kubeconfig" ] || exit 90` preceded the `sts assume-role` case, so
`aws sts assume-role` exited 90 every time and the `STS_ASSUME_FAIL` branch was unreachable.
The discriminator scenario therefore passed whether or not `STS_ASSUME_FAIL` was set. The case
is now above the guard, and the harness's behaviour changed as a result — which is what a
resurrected branch looks like, and confirms the diagnosis. The paired positive control
(`WHOAMI_REFUSE=1` without `STS_ASSUME_FAIL` must reach `Deescalated`) is still to be added.

**3. The persistent-failure case does not assert why it failed — NOT DONE.** The phase loop
only checks that the run fails; a failure at the pre-gate access step would satisfy it. It
should assert the gate's "could not be reached to check the whoami shape" text for the
`access` iteration, and the transient case should assert its first injected failure lands on
the gate's `update-kubeconfig` rather than an earlier step.

**4. Ticket staleness — PARTLY DONE.** The "Early shape gate" section still says a transient
failure "is reported" and the verification "stays fail-closed", which the code no longer does;
the hardening list still calls ambiguous arrays and the parse-failure mapping "not yet
applied", contradicting the table below it; and the STS discriminator, the widened 3-minute
bound (FND-0021 saw sub-45s propagation, which is the basis) and the same-build-path residual
are only in code comments.

**Minor, NOT DONE.** `SOL_WHOAMI_RETRY_INTERVAL_S` is parsed in three places and should be one
helper that rejects negative and NaN values. The `assume-role` stdout carries credentials and
must never be printed or included in `detail` (it is not today; keep it that way).

## Known red, and the correction (2026-09-21)

**The tree is NOT green.** An earlier note said "green and pushed" while also saying the new
head should fail the harness; that is a contradiction and the inviting one is wrong. The
accurate statement is:

> **Known red: the offline harness fails since the STS stub fix. Cause not yet confirmed.**

First failing message from the harness after the reorder (verbatim):

```
  whoami shape: not reachable yet (could not establish ephemeral provisioner cluster access); retrying in 0s
  cluster access identity: arn:aws:iam::111122223333:role/sol-cluster-access
error: the authorizer could not be reached to check the whoami shape (could not establish
ephemeral provisioner cluster access). The gate not having run is a failure, not a pass: the
run stops before the platform install rather than discovering an unreadable shape at
de-escalation.
```

**Cause: confirmed, and it is mine.** `bash -n` on the generated aws stub reports

```
/tmp/aws-stub.sh: line 74: syntax error near unexpected token `"$1 $2"'
/tmp/aws-stub.sh: line 74: `[ "$1 $2" = "eks update-kubeconfig" ] || exit 90'
```

so moving the `sts assume-role` case did split the surrounding `case ... esac`: the eks-only
guard now sits outside it, `aws eks update-kubeconfig` never matches its arm, and the failure
surfaces through `provisioner_kubeconfig` exactly as the error above shows. The fix is to
rebuild that `case` block properly rather than by text move.

That also means the earlier claim "the behaviour changed, which confirms the diagnosis" is
half right: it confirms the branch was dead, and says nothing about whether the discriminator
now passes or whether the positive path exposes a real bookkeeping mismatch. Those need
opposite responses, so the fresh session starts with the message above and the question it
leaves open.

## Pre-epoch items

**A. Item 1 -- the window stays open on failure (unchanged, highest priority).** See above.

**B. The capability answer must be tri-state -- this is a fail-open in the verdict.**
In `deescalation_probe` the probe currently reduces an answer to a `bool`:

```ocaml
| Ok r -> r.Sol_cli_process.exit_code = 0
| Error _ -> false
```

`false` means "denied", but `kubectl auth can-i` also exits non-zero when it cannot reach the
API, hits a transient error, or fails to get a token. If `whoami` succeeds and the `can-i`
calls then fail for a non-authorization reason, all three capabilities read as denied, the
principal is `Principal_confirmed`, and `deescalation_transition` returns `Deescalated`:
absence of evidence read as evidence, in the verdict itself. This belongs next to A, not in a
follow-up PR.

```ocaml
type capability = { verb : string; resource : string }
type answer = Permitted | Denied | Indeterminate of string
```

Parse stdout: `yes` is `Permitted`, `no` is `Denied`, anything else -- including a process
error -- is `Indeterminate`. Any `Indeterminate` makes the verdict `Undetermined`. Needs a
stub case where `can-i` exits 1 with a non-authorization error, and a mutant mapping it to
`Denied`. It also replaces the `(string * bool) list` and the `"create clusterroles"` strings
with something that cannot be misspelled.

## Ordering for the next session

1. **A** -- the window fix, with its harness case (`bootstrap-window` reads `false`).
2. **B** -- the `can-i` tri-state, with its stub case and mutant.
3. The paired positive control (`WHOAMI_REFUSE=1` without `STS_ASSUME_FAIL` must reach
   `Deescalated`) and the message assertions (Item 3 below).
4. Ticket staleness (Item 4 below).
5. The type-tightening refactors below, **after** the first live capture, so the parser being
   validated does not move underneath it.

## What the epoch is blocked on -- checklist

- [ ] A: a gate or control failure removes the bootstrap window (`bootstrap-window` = `false`)
- [ ] B: an indeterminate `can-i` answer cannot produce `Deescalated`
- [ ] Full-suite green on the head, **with the path named**
- [ ] The offline harness green on the head

**No live capture has happened yet.** Everything known about the shape of the authorizer's
answer is still the version recalled from the API; the parser has never seen a real response.

## Follow-up: tighten the types

Refactors, to land after the first capture. They touch the same functions the mutants target,
so every mutation check must be re-run afterwards.

**Two ARN types.** The bug class we kept hitting -- path normalisation, raw versus canonical --
is all `string`. The code already comments that the STS call needs the raw ARN while the
comparison needs the path-free one:

```ocaml
module Role_arn : sig type t val of_string : string -> t val to_string : t -> string end
module Canonical_role_arn : sig type t val of_role_arn : Role_arn.t -> t end
val principal_matches : expected:Canonical_role_arn.t -> whoami_identity -> ...
```

Passing the raw ARN to the comparison then becomes a compile error.

**`source : string` should be a variant.** The gate tests
`source <> "extra.canonicalArn" && source <> "userInfo.canonicalArn"`, so a typo silently
changes behaviour. Better: give the gate a type where canonical is *required*
(`canonical_arn : string`, not `option`), so a non-canonical identity cannot reach the
comparison at all. That removes the `arn` fallback in `principal_matches`, which can never
equal a role ARN anyway.

**The gate should return a result, not raise.**

```ocaml
type gate_failure =
  | Unparseable of string
  | Wrong_principal of string
  | Non_canonical of source
  | Unreachable of string
```

`cloud_init` converts it to `lifecycle_error` in one place, after `cleanup_bootstrap_access`.
That fixes the open-window issue **structurally** instead of by remembering `~on_error` at
every call site, and tests can assert the variant rather than message text.

**Small variants replacing option/bool combinations.** `sts_assumable : bool option` becomes
`Assumable | Not_assumable | Unchecked`; `principal_matches : bool option` becomes
`Match | Mismatch of string | Unnamed`; `cluster_refused : string -> bool` could return
`Refused | Other`.

**`deescalation_principal` mixes identity with outcome.** `Refused` and `Probe_failed` are not
principals, and `deescalation_verdict ~principal probes` accepts `Refused` with a non-empty
probe list -- an illegal combination. A probe outcome shaped as

```ocaml
| Answered of principal * capability_answer list
| Refused of string
| Failed of string
```

removes those states by construction; and once `Indeterminate` exists, the list can be made
non-empty by construction too.

**`before` should be evidence, not a list.** `verify_deescalation ~before` receives `[]` when
the control is `None` and relies on a runtime `Undetermined`. Give it an abstract
`Window_control.t` that can only be built from an observed `Permitted`, and bundle it with the
role ARN in one `bootstrap_verification option` so the three separate matches on
`provisioner_role_arn, outputs` collapse into one -- the `None -> []` branch then cannot exist.

**Cleanup.** Delete `role_name_of_arn`, `principal_role_name` and `index_of_substring` from
the `.mli`: production uses only `normalize_role_arn` and `principal_matches`, and the rest
encode the role-name comparison rejected as fail-open. Only tests call them.

**One `Retry_interval` and `Attempts` type.** The env parsing is copy-pasted three times and
accepts negatives and NaN; `attempt 10` and `loop 18` should be named bounds.

**`run_id` needs a type and a monotonic or random source.**
`int_of_float (Unix.gettimeofday ())` can collide within a second if the gate is called twice.

## Status

Most of the remaining work is mechanical, with one exception: **B is a small design change,
not parenthesis surgery.** It alters a type that `deescalation_transition` and several tests
consume, and it needs its own mutant, so treat it as design work. A and the ticket edits are
the mechanical part; both should still be done fresh.

## Notes from the failed attempts at the stub region (2026-09-21)

Five attempts at rewriting the aws stub's `case` region by text all failed. Two findings worth
carrying forward, because both wasted a round here:

**The scratch-file method works, and one attempt produced a verified region.** Building the
replacement in a scratch copy of the whole stub and running `bash -n` on *that* -- rather than
editing the live file and reading the resulting harness failure -- parses clean on the first
try. The region that parses is: the `sts assume-role` case closed with its own `esac`, then
`[ "$1 $2" = "eks update-kubeconfig" ] || exit 90`, then the `--role-arn` case closed with
`esac`.

**The slicing hazard that produces a false green.** Replacing "from the outer `case` to the
last `esac`" is unsafe: the region is inside the generator heredoc, and a region boundary that
reaches past the last `esac` swallows the heredoc's `EOF` terminator. The stub then runs to
end-of-file, **the harness still exits 0**, and the only sign is bash's

```
warning: here-document at line 234 delimited by end-of-file (wanted `EOF')
```

That is the worst failure mode seen in this thread -- a green result with a corrupted fixture --
and the warning is the only tell. Bound the region by the heredoc terminator, exclusive, and
treat that warning as fatal.

**Also recorded:** the `sts` case was dead *before* the syntax break, because the original
diff placed it after the `--role-arn` case and after the `exit 90` guard. The ordering above
fixes both problems, but a reader working from the old hunk would reproduce the deadness.

**And the heredoc-quoting hypothesis is refuted:** the generator is `cat >"$tmp/bin/aws" <<'EOF'`
(quoted), so `$1`, `$2` and `$*` are not expanded at generation time. The literal `"$1 $2"` in
bash's error message already implied that; the check confirms it.

## The docs-only path, and why the head's green must be checked (2026-09-21)

The head moved from `290f685a` to `b5e2df48` on a docs-only commit, and the workflow classifies a
change by its paths and **deliberately skips the full suite** for docs-only. So a green on the
new head could come from the skip path and say nothing about the code.

Checked: the run for the current head carries the `test` job, plus `golden-path-smoke`, the
dockerfile smokes and the TypeScript demo -- the jobs a docs-only classification skips. So the
head is on the full-suite path, not the skip path. **It is still in flight**, so no green is
established yet.

When it reports, state it as "full-suite green on `<sha>`" only if the `test` job **completed**,
not merely appeared, and name the SHA. If it turns out to be skipped, the alternative is a
full-suite run on the code commit `290f685a`.

## Session close

**Epoch checklist:** A, B, and full-suite green on the head with the path named. Harness green is
done.

**Not yet true:** any claim that the recalled shape of the authorizer's answer is right. No live
capture has happened; the first one settles it.

A and B are the two places where a wrong verdict or an open window could still come out of a run,
so a fresh session should start with them.

## Taking the full-suite green (record both facts)

The head keeps moving by docs-only commits, so the SHA a green is read from may not be the SHA
that carries the code. When recording it, write down **both**:

1. the SHA whose `test` job ran to **completion**; and
2. whether any **code** commit sits between that SHA and the head.

If A and B land as code commits this resolves itself, because the head will carry code and run
the full suite. Until then, "full-suite green" without the pair of facts is not readable by
someone else.

## Handoff

The code state is as this record describes it, and this record has been wrong before -- it
briefly claimed a green tree while the harness was red, which review caught. So start by
verifying the state rather than trusting it: run the harness (it is self-diagnosing now), and
check the checklist items against the code.

The record's own caveats, stated rather than absent: no live capture has happened, the positive
refusal path is unit-only, and the head's CI is unresolved.
