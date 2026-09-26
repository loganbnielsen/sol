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
./establish.sh <cluster-name> <iam-role-name> [region] [kubectl-context]
```

The context must already have cluster-admin **in the platform** (the qualification
`cluster-access` identity has it cluster-scoped). It is passed explicitly because
`aws eks update-kubeconfig` rewrites a shared user entry — a context named for one
identity can silently authenticate as another.

## What must never happen

- `sol cloud apply` applying this, or any production Terraform root referencing
  `sol:qualifiers` or `sol-qualifier-transport` — a customer environment must not be
  able to acquire qualification scaffolding by running Sol's normal lifecycle.
- A target field naming the qualifier principal.
- Any verb added to provisioner, publisher, deploy or operator to make a test
  easier.

`internal/ci/check_qualification_transport.sh` asserts all of that, and
`internal/ci/test_qualification_transport_check.sh` proves the guard can fail.

## Evidence rule

The qualification record must name the identity that established transport
**separately** from the identities whose contracts are under test. Transport is
harness mechanics; it is never evidence about a production identity.
