# Qualification-only transport

DEC-039 / FND-0020.

A live qualification run sometimes has to drive a real transaction against an
application's **private** `ClusterIP` service. No Sol-provisioned production identity
can reach one, and that is deliberate: provisioner mutates infrastructure, publisher
publishes artifacts, deploy mutates workloads, operator observes. None of them should
be able to tunnel into an arbitrary application pod.

This directory exists so the harness can get connectivity **without** touching that
model.

## What it grants

| Resource | Verbs | Why |
|---|---|---|
| `pods`, `services` | `get`, `list` | resolve a service's selector to a pod to attach to |
| `pods/portforward` | `create` | the transport |

Nothing else. No mutating verb, no `pods/exec`, no `pods/log`, no `events`, no
`secrets`. Diagnosis stays the operator's job.

## Establishing it

```
./establish.sh <cluster-name> <iam-role-name> [region] [namespace]
```

No standing identity can write cluster-scoped RBAC — the installation authority is
de-escalated (ADR 0003) — so the script opens a **temporary cluster-admin window on its
own principal**, applies `transport.yaml`, and closes it. `[namespace]` is the namespace
the post-establishment check reads (default `default`); pass the application namespace
under qualification where one exists.

The window is closed by **deleting the access entry and recreating it**, never by
disassociating the policy: measured live, a disassociation was reported complete while the
authorizer still granted cluster-admin for minutes, so the API's own report is not evidence
that a privileged grant is gone (`FND-0021` / `INFRA-061`). Deleting the entry propagated
in under 45 seconds.

Establishment then **verifies the effective surface** as the qualifier, with real
authorized calls rather than the API's description, and refuses to leave a credential
behind when it cannot show the declared one:

- `kubectl auth whoami` names the qualifier principal (the identity of the observation);
- `get pods -n <namespace>` succeeds — the addressing grant is effective;
- `get secrets -n <namespace>` reports `Forbidden` — the grant is not broader than declared;
- `auth can-i create pods/portforward -n <namespace>` answers `yes`.

A failure at any of those leaves **no** access entry rather than a broad one. The retry
bound is `SOL_QUALIFIER_VERIFY_ATTEMPTS` (default 12) and
`SOL_QUALIFIER_VERIFY_INTERVAL_S` (default 15); the defaults are the live values, and the
offline test below lowers them.

`internal/ci/test_qualification_transport_establish.sh` runs the whole sequence against
stub `aws`/`kubectl` binaries and asserts the three outcomes: a narrow surface is accepted,
a surface broader than declared fails with the entry removed, and a manifest that did not
take effect fails with the window closed. It also asserts that no run ever reaches
`disassociate-access-policy`.

## What must never happen

- `sol cloud apply` applying this, or any production Terraform root referencing
  `sol:qualifiers` or `sol-qualifier-transport` — a customer environment must not be
  able to acquire qualification scaffolding by running Sol's normal lifecycle.
- A target field naming the qualifier principal.
- Any verb added to provisioner, publisher, deploy or operator to make a test
  easier.
- Closing the establishment window by disassociating the admin policy, or trusting
  `describe-access-entry` for it (`FND-0021`).

`internal/ci/check_qualification_transport.py` asserts the grant and reachability
directions, and `internal/ci/test_qualification_transport_check.sh` proves the guard can
fail.

## Evidence rule

The qualification record must name the identity that established transport
**separately** from the identities whose contracts are under test. Transport is
harness mechanics; it is never evidence about a production identity. Before a run
uses it, the run reports the effective-surface verification above, from the principal
that performed it.
