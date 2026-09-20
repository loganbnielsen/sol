---
id: INFRA-043
type: bug
severity: high
title: The deploy identity cannot create the boundary lease it is required to hold
source: HARDEN Run 7 / Attempt 7 — migrations ran and the deploy stopped one grant short of a workload
---

**Related:** HARDEN-002 (the Run 7 record), ADR 0002 (the deploy identity),
INFRA-025 (the deploy-identity RoleBinding), the boundary lease itself.

## The finding

Attempt 7 got further than any previous attempt. The platform reached `Ready` for the
third consecutive time, the migration **ran and completed** against RDS, and
`sol deploy` passed its migration gate:

```text
[svc] checkout/checkout_svc
Migrations: OK -- 1 declared migration(s) present in schema_migrations
```

It then stopped on one missing grant:

```text
error: exited with code 1: Error from server (Forbidden):
  configmaps "sol-boundary-lease-pluto" is forbidden:
  User "arn:aws:sts::…:assumed-role/sol-qual5-deploy/EKSGetTokenAuth" cannot get …
```

The deploy identity is the identity Sol requires for deployment (ADR 0002), and the
boundary lease is Sol's own object — so the deployment path cannot take the lease it
is obliged to take. Every `sol deploy` on a cloud target fails here, one step short
of a running workload.

## What is needed

- The deploy-identity Role grants what the deploy path actually does with the lease:
  read, create and update it, scoped to the workspace's own lease rather than all
  configmaps in the namespace.
- The grant is verified against the boundary lease's real verbs — a `resourceNames`
  entry that names the lease but not the verb it is used with reproduces this defect
  exactly.
- Offline coverage compares the granted verbs against the verbs the deploy path
  issues, so the next lease operation cannot arrive without its grant.

## Not in scope

The lease semantics. This is a missing grant, not a redesign of the boundary.

**Demo/example coverage:** Not applicable.

**TypeScript parity:** No language-parity impact.

## Implementation

The platform now installs a dedicated `sol-boundary-lease` Role and RoleBinding
in `default` for the `sol:deployers` group.  The grant contains only ConfigMaps
and the exact `get`, `create`, `update`, and `delete` verbs issued by the lease
implementation.  `check_production_infra.sh` pins both sides of that contract and
fails if either the issued operation set or the grant changes independently.

Kubernetes RBAC cannot apply `resourceNames` to `create` requests, and the workspace
name is not known when the platform installs, so the grant is **not** name-scoped: it
covers ConfigMaps in `default`.  The client names the generated
`sol-boundary-lease-<workspace>` object on every request; the grant is kept separate
from the application deploy role.

## Landed (2026-09-20)

Merged in #370. `check_production_infra.sh` passes, including its contract pinning the
granted verbs against the verbs the lease implementation issues.

**Outstanding (behavioural):** Run 8 must show `sol deploy` passing the lease step. The
offline contract proves the grant matches what Sol issues; it cannot prove the apiserver
accepts those requests for the generated object.

**Scope correction (audit):** the Role grants `get`/`create`/`update`/`delete` on
ConfigMaps in `default`; it is **not** name-scoped. `resourceNames` cannot apply to
`create`, and the workspace name is not known when the platform installs, so the other
verbs are unrestricted within that namespace too. Only the client's requests name the
generated lease.
