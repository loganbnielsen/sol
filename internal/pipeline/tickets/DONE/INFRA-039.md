---
id: INFRA-039
type: bug
severity: high
title: A long-running lifecycle operation must reacquire short-lived credentials
source: HARDEN-002 Run 5 Attempt 5 — sol cloud destroy could not authenticate against a billable target
---

**Related:** ADR 0002 (Sol owns the complete target lifecycle), ADR 0004,
HARDEN-002 (Attempt 5), INFRA-037 (the other teardown failure in the same run).

## The finding

Attempt 5's first two teardown attempts failed before touching anything:

```text
[terraform-init] FAILED (1.0s)
  Error: No valid credential sources found
  Error: failed to refresh cached credentials, refresh cached SSO token failed,
         unable to refresh SSO token, operation error SSO OIDC: CreateToken,
         https response error StatusCode: 400, InvalidGrantException
```

The `sol-qual` profile is AWS SSO, and its refresh token expired during the run.

Two things made this worse than an ordinary expiry:

- **The AWS CLI and Terraform disagreed.** `aws sts get-caller-identity` still
  answered for the same profile, because the CLI held usable cached role
  credentials while Terraform needed to refresh and could not. So the failure
  looked like a credentials problem only once the exact command was reproduced
  outside Sol; from inside `sol cloud destroy` it was one line of stderr under a
  failed stage.
- **The direction was the expensive one.** Provisioning, behaving and destroying
  take hours. Expiry that lands during *provisioning* wastes an attempt; expiry
  that lands during *teardown* leaves billable infrastructure standing and the
  only supported path to remove it stops working. That is a failure mode an
  operator cannot fix by waiting.

Neither is solved by longer-lived credentials, and that is not the proposal.

## What is needed

Sol's lifecycle must not depend on a credential source that can expire underneath
it without the lifecycle noticing. Concretely, an operation that expects to run
for hours should:

1. **Resolve its identity once, up front, and say what it is.** Every stage should
   be attributable to an identity, so "which credential did this stage use" is
   answerable from the run log rather than from the operator's shell history.
2. **Reacquire before each stage that needs credentials**, rather than capturing
   them at process start. The AWS CLI can export resolved credentials
   (`aws configure export-credentials --format env`), which is exactly the
   "refresh correctly" path Terraform could not take on its own for SSO.
3. **Fail closed and loud, and never partially.** A stage that cannot authenticate
   must not have mutated anything, and the error must name the profile/identity
   and the remedy. `sol cloud destroy` in particular must report that the target
   is still standing and still billing — silence there is the worst outcome.
4. **Not require a specific credential kind.** A static role, an SSO session and a
   CI-provided token should all work; the lifecycle should name what it resolved,
   not assume how it was obtained.

## Acceptance criteria

- The run log identifies the principal each credential-requiring stage used.
- Credentials are resolved per stage, not once at process start.
- An expired or unavailable credential produces a fail-closed error naming the
  identity/provider and the target's state, before any mutation.
- A destroy that cannot authenticate states explicitly that the target remains
  and remains billable.
- Covered offline: a fake credential source that expires mid-operation must fail
  the operation cleanly and produce that message, and a source that can be
  reacquired must let the operation continue.

## Deliberately not in scope

Making credentials longer-lived. The qualification run is not too long; the
lifecycle's assumption about credentials is too strong.

**Demo/example coverage:** Not applicable — no CLI surface change.

**TypeScript parity:** No language-parity impact.
