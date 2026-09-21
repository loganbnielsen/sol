---
id: INFRA-061
type: bug
severity: high
title: An EKS access-policy disassociation is reported as complete while the authorizer still honours it
source: audit finding FND-0021
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0021-disassociated-access-policy-remained-effective.md`

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
