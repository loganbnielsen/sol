# FND-0021 — a disassociated EKS access policy remained effective, leaving a credential broader than its declared contract

**Classification:** `VERIFIED_DEFECT` (provider behaviour) · **State:** `FIXED_UNQUALIFIED` (2026-10-03)
**Severity:** high · **Ticket:** `INFRA-061` (Sol's own de-escalation), `INFRA-060` (the qualification transport) · **Evidence:** `BEHAVIORAL`
**Found while:** establishing the qualification transport (DEC-039 / FND-0020)

State history: `OPEN` (2026-09-21) → `FIXED_UNQUALIFIED` (2026-10-03). *Fixed* in the sense
this finding's own "What would make it qualified" required: every path that revokes
privileged access now verifies the **effective** surface, and the one path that could not —
the qualification transport — no longer uses the disassociation at all. It deletes the
access entry and recreates it narrow, verifies the effective surface as the qualifier, and
leaves no entry behind when it cannot (`INFRA-061`, `INFRA-060`). *Unqualified* because the
provider behaviour itself remains unmeasured: whether the disassociation is a propagation
delay with a bound, or a persistent divergence, is `INFRA-061`'s criteria 1–2 and needs a
live cluster. Until then the API's report for this operation is treated as untrusted, which
is the fail-closed direction.

## The observation

To apply a cluster-scoped RBAC manifest, the qualification harness opened a
temporary establishment window on its own principal — associate
`AmazonEKSClusterAdminPolicy`, apply, disassociate — mirroring ADR 0003's temporary
installation authority. The disassociation was accepted and is reflected by the API:

```
$ aws eks describe-access-entry --cluster-name <cluster> \
    --principal-arn arn:aws:iam::<acct>:role/<qualifier> \
    --query 'accessEntry.accessPolicies' --output json
null
```

The cluster's own authorizer still granted the full policy. Not a `can-i` artefact —
this was a real read of an object the declared grant does not cover:

```
$ kubectl --context <qualifier> get secrets -n pluto-payments
NAME                 TYPE     DATA   AGE
charge-svc-secrets   Opaque   2      4h32m
sol-secrets          Opaque   2      4h32m
```

The principal was confirmed at the time of the read (`auth whoami` →
`assumed-role/<qualifier>/EKSGetTokenAuth`), RBAC was confirmed to contain nothing
broad (`clusterrolebindings` held only the transport binding and Kubernetes'
`system:*` defaults), and the discrepancy persisted for **more than five minutes**
and across repeated sessions.

Deleting the access entry instead took effect in under 45 seconds — so it is the
*policy disassociation* path that failed to propagate, not access-entry changes
generally.

## Why it matters

The credential was broader than the contract the harness had just written down, and
the API said otherwise. Two consequences:

- **For this run:** a transport established this way cannot be trusted to be
  transport-only, so it was not used. The entry was deleted rather than relied on.
- **Generally:** an access-policy revocation that the control plane reports as
  complete while the data plane still honours it is exactly the class of defect this
  qualification exists to find — a platform claim that does not survive contact with
  the provider's actual enforcement. Anything that reasons from
  `describe-access-entry` (an audit, a de-escalation check, a "window closed"
  assertion) inherits the error.

## What would make it qualified / falsified

- Reproduce it: associate, disassociate, and measure whether the effective surface
  narrows. If it narrows after a longer delay, the finding becomes a **propagation
  delay** with a measured bound, which is still a defect for anything asserting
  de-escalation synchronously.
- Or determine it is specific to this path (EKS access policies vs. access entries)
  and document the constraint.
- Either way, a harness that establishes a capability this way must **verify the
  effective surface**, never the API's description of it — the mistake this run made
  and then caught.

## Immediate consequence for the qualification transport

DEC-039's mechanism assumed the window could be opened and closed around a narrow
grant. Until this is understood, the qualification transport is **not established**,
and B3's `-svc` half remains blocked — now for a sharper reason than "no identity can
transport": the mechanism for creating one cannot yet be shown to leave only
transport authority behind.
