---
id: INFRA-025
type: feature
severity: high
title: Wire deploy_role_arn into an EKS access entry and namespace-scoped RBAC
source: DEC-030 correction; AUDIT-072; ADR 0002
---

**Depends on:** None.

**Related:** DEC-030 (identity-model correction this implements), AUDIT-072
(the already-decided `provisioner_role_arn`/`deploy_role_arn`/
`operator_role_arn` contract), ADR 0002 (provisioner/publisher/deployer/
operator negative boundaries), INFRA-022 (the provisioner precedent this
mirrors).

## Premise

`deploy_role_arn` is a real target field (parsed, preflight-checked, tested)
whose least-privilege IAM **policy contract** the bootstrap root already
generates. But nothing binds it to the cluster: `grep -rn deploy_role_arn
cli/platform/infra/*/*.tf` has zero matches, so even with the IAM role
created and the generated policy attached exactly as documented, `sol
deploy` still has no `kube_context` to reach the cluster as that identity —
the error a user hits (`sol_cli_kube_destination.ml`'s "no Kubernetes
context is configured") names a fix (`sol cloud init`) that both doesn't
exist as a command and wouldn't populate this field even if it did.

## What already works (the pattern to mirror)

`provisioner_role_arn` is fully wired in `cli/platform/infra/aws/main.tf`:
an `access_entries.platform_provisioner` block maps the ARN to Kubernetes
group `sol:platform-provisioners`, with `policy_associations` granting
`AmazonEKSClusterAdminPolicy` only for the temporary
`provisioner_bootstrap_admin` window. Steady-state provisioner permissions
come from `cli/platform/infra/base/platform_provisioner_rbac.tf`'s own
`kubernetes_cluster_role`/`kubernetes_cluster_role_binding`, not from an
AWS-managed policy — the access entry only supplies the group membership.

## Why deploy can't just copy that shape verbatim

The provisioner's Kubernetes RBAC is scoped by **resource kind** (platform
CRDs, namespaces, RBAC objects it needs) and is safe to grant
cluster-wide via a `ClusterRoleBinding` because none of those kinds include
ordinary application `Secret`s. Deploy is different: it must mutate
`Deployment`/`Service`/`Job`/`ConfigMap`/`Secret` objects, and granting that
cluster-wide would let it read/mutate the **same resource kinds inside
platform namespaces** — the ingress controller and Argo CD `Deployment`s,
cert-manager's `Secret`s, any platform `Secret` — which is exactly the
"provisioner/deployer must not subsume" boundary ADR 0002 requires, just
inverted (deploy reaching into platform namespaces instead of provisioner
reaching into application ones). A `ClusterRole` scoped to those resource
kinds is still fine to define cluster-wide (a `ClusterRole` grants nothing
until bound), but the **binding** must be namespace-scoped — and application
namespaces are created dynamically per workspace by `Sol_cli_substrate.ensure`
(`cli/sol/bin/cmd_deploy.ml:339`, `cmd_migrate.ml:462,697`), not known at
Terraform-apply time, so a static namespace list in an EKS access-entry
`access_scope` can't express it either.

## Mechanism (no new decision needed — follows from the above)

1. **AWS root** (`cli/platform/infra/aws/main.tf`): add `deploy_role_arn`
   (mirroring `provisioner_role_arn`'s variable) and an
   `access_entries.deploy` block mapping it to Kubernetes group
   `sol:deployers`, with no policy association (same as provisioner's
   steady state — the group membership is the only thing this layer
   supplies). Output a `deploy_kubeconfig_command`, mirroring
   `kubeconfig_command`, with `--role-arn ${var.deploy_role_arn}`.
2. **Platform/base root**: a `sol-deploy` `ClusterRole` granting the verbs
   `sol deploy`/`sol migrate`/`sol rollback` actually issue against
   `Deployment`/`Service`/`Job`/`ConfigMap`/`Secret` (check
   `Sol_cli_kubectl`'s call sites for the exact verb set rather than
   guessing `*`). Cluster-scoped resource definition; grants nothing until
   bound, matching the provisioner precedent's own safety argument.
3. **`Sol_cli_substrate.ensure`**: when it creates an application namespace,
   also apply a `RoleBinding` in that namespace binding group
   `sol:deployers` to `ClusterRole/sol-deploy` — the same per-namespace
   bootstrap responsibility this function already owns for the namespace
   itself. Platform namespaces never go through `ensure`, so they never
   receive this binding.
4. **`sol cloud apply`** prints the `deploy_kubeconfig_command` output and
   the resulting context name (same treatment as the provisioner's own
   `kubeconfig_command`, which is printed via `print_outputs`, not silently
   consumed) — it does **not** write `kube_context`/`kubeconfig` into the
   target file. Per DEC-030's correction: the deploy identity is typically
   used by a different actor/session (a human, or a separate CI job) than
   whoever ran `sol cloud apply`, so auto-writing assumes a same-session
   ownership that doesn't hold in general, and AUDIT-072's "Sol owns the
   contract, not the lifecycle" philosophy already leans toward telling the
   operator the exact command over mutating state on their behalf. Update
   `sol_cli_kube_destination.ml`'s and `sol_cli_target_report.ml`'s error
   strings from "let `sol cloud init` record it" to naming the printed
   `deploy_kubeconfig_command` output instead — this is the actual `sol
   cloud init` text fix, once this exists to describe truthfully.
5. Update `docs/deployment/production-bootstrap.md` (§2) to show the
   resulting `kube_context`/`kubeconfig` lines the operator adds, the same
   way it already shows the three role ARNs.

## Acceptance criteria

- A target with `deploy_role_arn` set, after `sol cloud apply`, has an EKS
  access entry mapping it to `sol:deployers`; a fresh application namespace
  created by `Sol_cli_substrate.ensure` carries a `RoleBinding` granting
  `sol:deployers` exactly the declared verbs on the declared resource kinds,
  and nothing else (verified negatively: `kubectl auth can-i` as that
  identity denies an operation on a platform namespace's `Secret`/
  `Deployment`, mirroring the offline effective-permission style INFRA-024
  used for the publisher/deployer code-path boundary, but for this RBAC
  boundary specifically).
- `sol cloud apply` prints the exact command + context name; it makes no
  target-file write.
- The `sol cloud init` error-message text names a command/output that
  actually exists.
- Offline coverage: extend `internal/ci/test_cloud_lifecycle_offline.sh`
  (or a fixture-based HCL/RBAC-shape test, matching whatever the repo's
  existing pattern is for asserting a `kubernetes_cluster_role_binding`'s
  subject/scope) proving the RBAC binding is namespace-scoped, not cluster-
  wide, and that no `deploy` access entry is created when `deploy_role_arn`
  is unset (mirrors `provisioner_role_arn`'s `== "" ? {} : {...}` guard).
- Live verification (does `sol:deployers` actually deny platform-namespace
  mutation against a real EKS access-entry group-to-RBAC binding, and does
  the operator's `aws eks update-kubeconfig --role-arn` round-trip work)
  remains HARDEN run 3's, per this pass's instructions — do not promote this
  ticket's offline RBAC-shape evidence into a live qualification claim.

**Demo/example coverage:** update `docs/deployment/production-bootstrap.md`
per item 5 above; no example/fixture changes needed (Pluto's target files
already exercise `provisioner_role_arn`-style fields via test fixtures, not
example-tree files).

**TypeScript parity:** not applicable — target provisioning and Kubernetes
RBAC are language-neutral (DEC-022).

## Completion notes (2026-09-18)

**Premise verified:** confirmed at branch start — `deploy_role_arn` had zero
matches in `cli/platform/infra/*/*.tf`, and `sol_cli_kube_destination.ml`/
`sol_cli_target_report.ml` still named `sol cloud init`.

- **Item 1.** `cli/platform/infra/aws/variables.tf`/`main.tf`/`outputs.tf`:
  `deploy_role_arn`, an `access_entries.deploy` block (group
  `sol:deployers`, no policy association), and `deploy_kubeconfig_command`/
  `deploy_kube_context` outputs. Deliberately a **different alias**
  (`${cluster_name}-deploy`) than the provisioner's `kubeconfig_command`
  (`${cluster_name}`) — both may be run against the same local kubeconfig
  file, and `--alias` collisions overwrite the earlier context entry.
- **Item 2.** `cli/platform/infra/base/platform_deploy_rbac.tf`: a
  `sol-deploy` `ClusterRole` scoped to the exact resource kinds
  `sol_cli_manifest_yaml.ml` renders (`ConfigMap`/`Secret`/`ServiceAccount`/
  `Service`/`Deployment`/`Job`/`CronJob`/`PodDisruptionBudget`/`Ingress`/
  `NetworkPolicy`/`Rollout`/`ExternalSecret`, plus read-only `pods`/
  `pods/log`), not a wildcard.
- **Item 3.** `Sol_cli_substrate.ensure` now applies a `deploy_role_binding_doc`
  (new in `Sol_cli_manifest_yaml`) per namespace.
- **Item 4.** No target-file write; the printed `deploy_kubeconfig_command`/
  `deploy_kube_context` outputs (already surfaced by the existing generic
  `print_outputs`) are what the error text now points at.
- **Item 5.** Done — `docs/deployment/production-bootstrap.md` §2 gained a
  worked example of the printed output and the `kube_context` line to add.

**A real gap found in review, not fully closeable in this ticket:** working
through exactly how `Sol_cli_substrate.ensure` bootstraps a namespace it has
never seen (namespace creation and the RoleBinding that grants everything
else are both things deploy cannot yet have permission to do — a
namespace-scoped `RoleBinding` cannot itself authorize creating a namespace
or a `RoleBinding`, since `Namespace` is cluster-scoped and Kubernetes RBAC
never lets a `RoleBinding` cover a cluster-scoped resource kind) required a
second, minimal `sol-deploy-bootstrap` `ClusterRole`+`ClusterRoleBinding`:
`namespaces`/`rolebindings` `get,list,watch,create` only (never
update/patch/delete, so it can create new objects but never mutate an
existing one, platform ones included), plus `clusterroles` `bind` restricted
by `resource_names` to exactly `sol-deploy` (satisfying Kubernetes' own RBAC
escalation check — creating a `RoleBinding` that references a `ClusterRole`
requires either already holding every permission in it or the `bind` verb
scoped to it — without which deploy could reference *any* `ClusterRole`,
including a future one with broader rights).

That bootstrap grant has a real residual gap, found by re-deriving the
threat model rather than only checking the acceptance criteria as written:
**`rolebindings: create` cannot be restricted by namespace when bound via a
`ClusterRoleBinding`** (`resourceNames` is not honored for `create` at all,
per the Kubernetes API itself, and RBAC has no partial-cluster-scope
binding). So the deploy identity's own raw credential could, in principle,
create a `RoleBinding` named `sol-deploy` directly inside a platform
namespace (`cert-manager`, `argocd`, ...), which would then grant it
`sol-deploy`'s full `Secret`/`Deployment` rights there too — the exact
outcome this ticket exists to prevent. Closing this completely needs an
admission-control layer (a `ValidatingAdmissionPolicy` denying non-provisioner
`RoleBinding` writes in platform namespaces, or equivalent) that Sol does not
have today; adding one is out of scope for this ticket and not invented here.

**Accepted mitigation, not a full fix:** `Sol_cli_substrate.reserved_platform_namespaces`
+ a client-side refusal in `ensure` stops every *ordinary* path (`sol deploy`,
`sol migrate apply`) from touching a namespace whose name collides with a
platform one — DEC-016's "`local` is reserved" pattern, extended. It does
**not** stop a deliberate holder of the deploy credential from bypassing
Sol's CLI and issuing the `RoleBinding`-create API call directly. This is a
knowingly incomplete boundary, documented rather than silently shipped as
solved: **today there is no deploy RBAC boundary at all** (any configured
`kube_context` has whatever access its operator manually granted), so this
is a substantial narrowing of that gap, not a claim that it is closed. The
admission-control layer needed to close it fully is real follow-up work,
better scoped once Sol has a reason to adopt that layer for other purposes
too, rather than a one-off addition here.

**Offline evidence:** `cli/sol/test/check_production_infra.sh` gained
structural assertions: `sol-deploy` is never referenced by a
`kubernetes_cluster_role_binding` (only namespace-scoped `RoleBinding`s, at
runtime); `sol-deploy-bootstrap`'s `namespaces`/`rolebindings` rule is
create-only; its `clusterroles` rule scopes `bind` to `sol-deploy` by
`resource_names`; the AWS root's `access_entries` guards `deploy_role_arn`
being unset. `test_substrate.ml` covers the new RoleBinding doc's shape/
ordering and the reserved-namespace refusal (a pure check, provably
short-circuits before any kubectl call — passed `local_context` on purpose
to demonstrate that). Live verification (does `sol:deployers` actually deny
platform-namespace mutation against a real cluster; does the bootstrap
"create-only" grant behave as expected against the real API server) remains
HARDEN run 3's.
