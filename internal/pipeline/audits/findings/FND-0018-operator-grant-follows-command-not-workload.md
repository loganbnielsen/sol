# FND-0018 — the operator diagnostic binding follows the command, not the workload

**Classification:** `VERIFIED_DEFECT` · **State:** `QUALIFIED` (2026-09-21) · **Severity:** high
**Ticket:** `INFRA-058` · **Contract:** DEC-038 §6 (clarified 2026-09-21)
**Derived from:** FND-0017's first live verification · **Evidence:** `BEHAVIORAL`

## The defect

The operator's diagnostic RoleBinding is created by the substrate step, and the
substrate step is **namespace-scoped to whatever the command is operating on**.
So a namespace gets the operator's grant only if it happens to participate in a
`deploy`/`migrate` after the grant existed.

Live, against the preserved Run 8 target:

```
pluto-checkout     sol-operator-diagnostics -> sol:operators
pluto-payments     Error from server (NotFound): rolebindings.rbac.authorization.k8s.io "sol-operator" not found
pluto-comms        Error from server (NotFound): rolebindings.rbac.authorization.k8s.io "sol-operator" not found
```

`pluto-checkout` has it because that is the namespace `sol migrate apply` migrated.
`pluto-comms` — where the workload under investigation actually runs — does not.
Probed directly:

```
kubectl --context sol-qual5-operator auth can-i list pods   -n pluto-comms   ->  no
kubectl --context sol-qual5-operator auth can-i list events -n pluto-comms   ->  no
kubectl --context sol-qual5-operator auth can-i get pods/log -n pluto-comms  ->  no
```

## Why it matters

- The identity Sol now provisions cannot diagnose most of the workspace it exists
  to observe. It is not a permissions bug — the role is right — it is a
  **distribution** bug: the grant is delivered per-command rather than per-workload.
- The only existing thing that would create the missing binding is deploying the
  workload again, which **mutates the very thing being diagnosed**. Any workspace
  predating DEC-038 is in this state, so the correct behaviour after an upgrade
  would require redeploying production to become diagnosable — unacceptable, and
  in a qualification run it would destroy the evidence.

## The invariant (DEC-038 §6)

Every namespace containing a Sol-managed workload must have the operator
diagnostic RoleBinding, independent of whether that namespace participated in the
current deploy/migrate operation. Existing namespaces count.

The reconciliation must be **RBAC-only**. It must not reuse a substrate path that
also writes runtime Secrets or otherwise mutates workload configuration: those
side effects belong to deployment, not to establishing read authorization, and
running them to fix permissions would be both the wrong abstraction and a hazard.

## What would make it qualified

- A pure reconciliation establishes the binding in every workload namespace,
  exercised live against the preserved `pluto-comms` **without** redeploying or
  restarting the workload.
- Regression coverage that an existing namespace receives the binding without any
  Secret or workload document being written.
- The operator then obtains the same degraded evidence the correctly authenticated
  deploy identity obtained (see FND-0019 for what happened instead).

## Resolution (2026-09-21)

`reconcile_operator_bindings` establishes the grant across every namespace holding a
Sol-managed workload, derived from the workspace's service inventory rather than any
caller's scope. Live, after one `sol migrate apply`:

```
pluto-checkout     sol-operator-diagnostics
pluto-payments     sol-operator-diagnostics
pluto-comms        sol-operator-diagnostics
```

`pluto-comms` was unreadable before and is the namespace the workload under
investigation runs in. `notify-worker` was not restarted or redeployed to achieve
it -- same pods, same creation timestamps -- which is the part of the invariant that
mattered most: diagnosability must not require mutating what is being diagnosed.

**A second, smaller defect was found live in the first implementation**, and is
recorded because it is the same class as the finding: the loop was fail-fast, so
`pluto-demo-ts` -- a service present in the workspace but never deployed, and
therefore a namespace that does not exist -- aborted the reconciliation and left
`pluto-payments`, a real running workload, without its grant. A namespace that does
not exist holds no workload, so it is nothing to do; every other failure is collected
and reported. Partial application was the bug, not the error handling.
