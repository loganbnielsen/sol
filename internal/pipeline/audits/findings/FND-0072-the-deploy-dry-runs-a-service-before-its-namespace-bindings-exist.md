---
id: FND-0072
type: audit-finding
severity: high
source: AWS attempt 32, resumed specimen — `sol deploy` stopped at the server-side dry-run
---

**Depends on:** None.

**Related:** FND-0071 (the identity boundary this attempt established),
`cli/lib/deploy/sol_cli_substrate.ml`, `cli/lib/deploy/sol_cli_deploy_run.ml`,
`internal/qualification/records/2026-09-30-aws-attempt32-cloud-boundary-passes-deploy-blocked-at-substrate.md`.

# The deploy dry-runs a service's manifests before that namespace's bindings exist

## What happened

With the identity boundary fixed (FND-0071 — the deploy path now reaches the cluster as the
deploy identity, verified live by `can-i`), `sol migrate apply` completed on the resumed
specimen. `sol deploy` then failed while preparing `notify_worker`:

```
error: kubectl server-side dry-run failed: exited with code 1: Error from server (Forbidden):
error when retrieving current configuration of: … /tmp/sol-manifest-431065.yaml:
serviceaccounts "notify-worker" is forbidden: User
"arn:aws:sts::876701109436:assumed-role/sol-qual5-deploy/EKSGetTokenAuth" cannot get resource
"serviceaccounts" in API group "" in the namespace "pluto-comms"
```

…with the same refusal for `configmaps`, `secrets`, `networkpolicies`,
`poddisruptionbudgets` and `deployments` in that namespace.

## Why

The namespace exists and was created by this same deploy — `pluto-comms` is four minutes old at
the point of failure — but it holds **no RoleBinding**:

```
pluto-checkout   sol-deploy      ClusterRole/sol-deploy                9m31s
pluto-checkout   sol-operator    ClusterRole/sol-operator-diagnostics  9m30s
pluto-comms      (none)
```

`pluto-checkout`'s bindings were created by the earlier `sol migrate apply`, which called
`Sol_cli_substrate.ensure ~namespaces:[ namespace ]`. `sol deploy` calls
`Sol_cli_substrate.ensure ~namespaces:(Sol_cli_substrate.namespaces plan)` — the plan's service
namespaces, which include `pluto-comms` — but the observed state says the namespace was created
while its bindings were not, and the dry-run for that namespace's manifests had already run by
then.

So either the binding step is not reached for a namespace the plan covers, or the dry-run is
sequenced before the ensure that would authorise it. Which of the two is not established here:
the next step is to read `sol_cli_deploy_run`'s ordering against `Sol_cli_substrate.ensure`'s
binding construction and confirm whether the ensure ran, with what namespace list, and whether
its failure to bind is silent.

Nothing here is an identity problem: the deploy identity holds `sol-deploy`, which grants every
resource named in the refusals, and the live boundary check confirms it can create rolebindings
in a workspace namespace. It is an ordering or coverage gap in bootstrapping those bindings.

## Acceptance criteria

- The mechanism is established: either the deploy path's dry-run is sequenced after the substrate
  ensure for that namespace, or the ensure covers every namespace the plan will dry-run.
- A failed or skipped binding step cannot be silent — if the substrate cannot create a binding it
  must say so before a manifest operation is attempted in that namespace.
- Live coverage: `sol deploy` completes on a fresh AWS specimen, and the workspace namespaces of
  the deployed services each carry the `sol-deploy` and `sol-operator` bindings.
