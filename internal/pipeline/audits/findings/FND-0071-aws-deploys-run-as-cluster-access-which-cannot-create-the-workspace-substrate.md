---
id: FND-0071
type: audit-finding
severity: high
source: AWS attempt 32 — the application row stopped at the first step of `sol migrate apply`
---

**Depends on:** None.

**Related:** FND-0070 (independent verification of provider reality), DEC-034 (the cluster
identity split), AUDIT-072 (`platform/cloud/modules/platform/platform_deploy_rbac.tf` — the
namespace-scoped application identity), `platform/cloud/modules/platform/platform_provisioner_rbac.tf`,
`cli/lib/cloud/sol_cli_aws_cluster.ml`, `internal/qualification/records/2026-09-30-aws-attempt32-cloud-boundary-passes-deploy-blocked-at-substrate.md`.

# AWS deploys run as the cluster-access identity, which cannot create the workspace substrate

## What happened

Attempt 32 reached a healthy, `Ready` AWS platform and pushed both application images. The deploy
path then failed at its first cluster mutation:

```
error: kubectl create (workspace substrate): exited with code 1: Error from server (Forbidden):
error when creating "/tmp/sol-substrate-a94b42.yaml": rolebindings.rbac.authorization.k8s.io is
forbidden: User "arn:aws:sts::876701109436:assumed-role/sol-qual5-cluster-access/EKSGetTokenAuth"
cannot create resource "rolebindings" in API group "rbac.authorization.k8s.io" in the namespace
"pluto-checkout"
```

The named identity is the target's **cluster-access** role, in three separate attempts, including
one where the ambient kubeconfig's current context was the deploy context. The identity therefore
comes from Sol, not from the shell: the deploy path reaches the cluster through
`Sol_cli_cluster.with_access`, and `Sol_cli_aws_cluster.provisioner_kubeconfig` defaults
`--role-arn` to `cluster_access_role_arn` when no role is given. On AWS, `with_access` is that
path.

Earlier in the same attempt the substrate step also failed as the **operator** identity
(`namespaces is forbidden … sol-qual5-operator`), which is the same gap one step earlier.

## Why the identity does not have the authority

The authority the step needs is already declared — for a different identity.
`platform/cloud/modules/platform/platform_deploy_rbac.tf` declares
`kubernetes_cluster_role.sol_deploy_bootstrap` granting exactly the workspace substrate's needs:

- `namespaces`: get, list, watch, create;
- `rolebindings` (namespaced): get, list, watch, create;
- `bind` on the named cluster roles `sol-deploy` and `sol-operator-diagnostics`.

That ClusterRole is bound to group **`sol:deployers`**. On AWS
(`platform/cloud/aws/cluster/main.tf`) `sol:deployers` is the **deploy** role's group, while the
cluster-access role is in **`sol:platform-provisioners`**, whose ClusterRole
(`platform_provisioner_rbac.tf`) grants cluster-scoped `clusterroles` and `clusterrolebindings`
but no namespaced `rolebindings`, and no `bind`.

So the two halves disagree: the grants belong to the deploy identity, and the deploy path runs as
the cluster-access identity. This is provider-visible because the AWS `with_access` resolves to a
scoped identity; the GCP row completed this step, and whether that is because its equivalent
resolves to a broader identity or because of an installed-RBAC difference has **not** been
established here and should be checked before choosing a fix.

## Why this is filed rather than fixed

Either resolution changes who may mutate what:

1. **Grant the deploy-bootstrap authority to the platform provisioner group** — e.g. bind
   `sol-deploy-bootstrap` to `sol:platform-provisioners` as well. Sol's deploy path then works as
   written, at the cost of widening the durable platform identity's authority to include creating
   rolebindings in application namespaces.
2. **Make the deploy path assume the deploy identity** for the workspace substrate and workload
   apply, matching the RBAC's existing intent, and keep cluster-access to the platform lifecycle.
   That is a change to which identity performs application mutations, and to how the deploy path
   obtains credentials.

Both are authority decisions, so the row stopped at the first unexpected result and the specimen
was left standing rather than patched through.

## Acceptance criteria

- One resolution is chosen and recorded as a decision, with the security reasoning for the group
  that gains the authority.
- The chosen path is exercised live: `sol migrate apply` and `sol deploy` reach a namespace-scoped
  substrate step on a fresh AWS specimen without an authority error.
- Regression coverage states which identity performs the workspace substrate mutation, so a
  future change to either the RBAC group or the `with_access` role fails a test rather than a
  qualification run.
