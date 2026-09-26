---
id: INFRA-089
type: bug
severity: high
title: The platform apply cannot create the GCP provisioner RoleBindings because another resource already owns that Kubernetes name
source: GCP Attempt 11 (main @ 17afc4b2) — the first blocker exposed once cert-manager was fixed; FND-0061
---

**Depends on:** None.

**Related:** FND-0061 (the finding, with the frozen evidence and the config lines), FND-0060 (the
fix that let the install get this far), `platform/cloud/modules/platform/platform_provisioner_rbac.tf`,
record `internal/qualification/records/2026-09-26-gcp-attempt11-cert-manager-qualified-new-blocker.md`.

## What was observed (FACT, live)

```
[platform-prerequisites-apply] ok (143.7s)
[platform-apply] FAILED (201.6s)
  rolebindings.rbac.authorization.k8s.io "sol-platform-provisioner" already exists
    module.platform.kubernetes_role_binding.platform_provisioner_gcp["redpanda"]
    (and "ingress-nginx", "monitoring", "cert-manager", "argocd")
```

`platform_provisioner_rbac.tf` declares **two** `kubernetes_role_binding` resources over the same
namespace set, both writing the Kubernetes name `sol-platform-provisioner`:
`platform_provisioner` (subject: Group `sol:platform-provisioners`) and `platform_provisioner_gcp`
(subject: the configured GCP provisioner ServiceAccount, empty when none is configured). The
targeted prerequisites step names the first in its `-target` list, so it creates the objects and
records them; the full apply then cannot create the second, and the platform install stops there —
so `Ready` is unreachable on a fresh GCP target.

This was invisible until now because cert-manager failed inside that same prerequisites step, so
the full apply never ran (Attempts 4/5/8/9/10). It is deterministic, not a run artifact: both
resources are always declared for a GCP target.

## Decision taken (2026-09-26): one RoleBinding, both subjects

The operator chose the one-object model, conditional on the authorization-lifetime analysis
holding: both subjects must hold the same role, in the same namespaces, over the same lifecycle.
It holds, and the evidence is in the code:

- **Same role.** Both bindings reference the same ClusterRole — `sol-platform-provisioner-namespaced`
  for the namespaced pair, `sol-platform-provisioner-cluster` for the cluster pair.
- **Same namespaces.** Both use `local.platform_namespaces`.
- **Same lifetime.** Both are declared in this module, created by the platform install and removed
  by platform destruction. Nothing in the lifecycle adds or removes one independently: the
  de-escalation path closes the *bootstrap-authority* window
  (`kubernetes_cluster_role_binding.provisioner_bootstrap_admin`, the capability's
  `bootstrap_matchers`), not these bindings.
- **Why two subjects exist at all.** They differ only in how a cloud identity reaches the API
  server: AWS's provisioner is placed in the Kubernetes group `sol:platform-provisioners` by its EKS
  access entry (`platform/cloud/aws/cluster/main.tf`), while a GKE identity authenticates as itself
  and belongs to no group Sol can name. Same authority, two doors.

So the invariant is **one Kubernetes API object, one Terraform owner**, and the fix is one
RoleBinding carrying both subjects — not two objects with different names, which would exist only
to satisfy Terraform.

## Terraform state / migration analysis

**No migration machinery is added, and none is needed for the retained addresses.** Two facts:

- The retained resources keep their addresses (`kubernetes_role_binding.platform_provisioner`,
  `kubernetes_cluster_role_binding.platform_provisioner_cluster`), so their existing instances and
  the AWS root's `moved` blocks that already point at them stay valid. The GCP subject appears on
  those objects as an in-place update.
- The removed resources (`..._gcp`) cannot appear in any supported state: they could never be
  created, because their Kubernetes names were already owned by the retained resources. Measured,
  not assumed: all five platform states in the qualification bucket (`prod`, `qual`, `qual9`,
  `qual10`, `qual11`) hold zero resources, and on AWS `local.gcp_provisioner` is empty, so the
  resource has no instances there at all.

Two **stale** `moved` blocks in the AWS root did name the removed addresses, and a `moved` block
whose destination no longer exists is a configuration error — so they are deleted with the
resources. That is the only migration work this change does.

## Status

Implemented 2026-09-26. Offline acceptance met; **live acceptance is the next qualification run**
(the discriminator below), and FND-0061 stays `FIXED_UNQUALIFIED` until it happens.

## Acceptance criteria

- A fresh GCP qualification target's `platform-apply` completes and the install continues past this
  point (toward the next component, and ideally `Ready`).
- An executable guard (or a structural check in the existing platform-RBAC guard family) rejects a
  module in which two RoleBinding resources resolve to the same Kubernetes name in the same
  namespace, with a mutation proof.
- Any target already carrying the earlier objects can still apply — stated explicitly if the chosen
  direction changes an address.

## Not in this ticket

No timeout changes, no cert-manager changes (that work is qualified), no authority/destruction
semantics, no AWS work, and no live mutation without separate authorization. Nothing was repaired
during Attempt 11: no `terraform import`, no state surgery, no manual RBAC edit, no re-run of the
failed step.

## Completion notes (2026-09-26)

**Problem.** A fresh GCP target's platform install could not get past the full platform apply: two
Terraform resources wrote the same Kubernetes RoleBinding name (`sol-platform-provisioner`), so the
targeted prerequisites step created the object and the full apply failed with `already exists`
(FND-0061). The cluster-scoped pair had the same defect waiting behind it.

**Root cause.** Two resources, one Kubernetes object — and the pair existed only because the AWS and
GCP provisioner identities reach the API server differently (group membership vs. direct User), not
because they need different authority. Terraform enforces one owner per object; the configuration
declared two.

**Change.**

- `kubernetes_role_binding.platform_provisioner` and
  `kubernetes_cluster_role_binding.platform_provisioner_cluster` now carry both subjects, the GCP
  one via a `dynamic "subject"` block gated on `local.gcp_provisioner`, so an AWS tree renders
  exactly what it did before.
- `kubernetes_role_binding.platform_provisioner_gcp` and
  `kubernetes_cluster_role_binding.platform_provisioner_cluster_gcp` are deleted.
- The two AWS-root `moved` blocks that named the deleted addresses are deleted with them (a `moved`
  destination that no longer exists is a configuration error). No migration machinery is added: the
  retained addresses keep their addresses, and the removed ones cannot exist in any supported state
  (measured across all five qualification-bucket states; structurally empty on AWS).
- The stale comment that called the group+identity model "the cosmetic version" is replaced with the
  reasoning that decided it — same authority, same lifetime, one owner — so the next reader sees the
  argument rather than an unexplained reversal.

**Executable evidence.**

- `internal/ci/check_kubernetes_object_ownership.sh` — the invariant, not the incident: within a
  platform root, two Terraform-managed Kubernetes objects must not resolve to one
  `(kind, namespace, name)` unless both say `# same-object-owner: <why>`. Public run on the fixed
  tree: 28 resolvable objects across 13 files, no collisions, 2 dynamic names recorded.
- `internal/ci/test_kubernetes_object_ownership_check.sh` — nine cases: the RoleBinding collision
  (the live failure), the cluster-scoped collision, a one-sided marker (rejected), the declared
  exception (accepted), same name in different namespaces (accepted), same name different kinds
  (accepted), an undecidable namespace expression (accepted, *reported*), an unresolvable dynamic
  name (accepted, recorded), and the real tree.
- `terraform fmt -check` clean; the platform module and both provider roots validate.
- The qualification harness's classification ordering is corrected separately (see below).

**Instrument correction (same unit, per the operator).** `classify_fnd0010` now reads the failed
operation's own log first and classifies a Terraform `already exists` resource conflict as
`TERRAFORM_ALREADY_EXISTS`; the ambient `FailedScheduling` evidence moved last and is now labelled
`SCHEDULING_AMBIENT`, because a half-installed cluster always has a pod waiting to be scheduled.
Two new harness assertions pin both directions (133 total).

**A bounce worth recording (CI, exit 126).** The first CI run of this change failed at the new
guard step with exit code 126: the mutation self-test was committed `100644` while the workflow
invokes it directly, and every local run had used `bash <script>`, which does not need the bit —
so the local sweep could not see it. Two things came out of that: the mode is fixed (matching the
72 other executable scripts in `internal/`), and `check_workflow_paths.sh` now also refuses a
script the workflow invokes as a command without the executable bit, with three mutation cases
(a directly invoked script at 644 fails, at 755 passes, and a `bash <script>` invocation needs no
bit at all).

**Demo/example coverage:** not applicable — platform installation RBAC, with no `sol.toml` field,
CLI surface, framework primitive or generated manifest for an app author to read or run; the
observable behaviour is a fresh target's platform apply completing, which the next live run shows.

**Language parity (DEC-022):** no application-facing impact; no primitive, contract, metric or
retry semantic is involved, and neither application language observes platform RBAC.

**Canonical merge SHA:** `git log --oneline -1 -- internal/pipeline/tickets/DONE/INFRA-089.md`.

**Live acceptance (discriminator for the next authorized run):** on a fresh GCP target, the
targeted prerequisites step and then the full `platform-apply` both complete; the ClusterRoleBinding
and the RoleBindings in each platform namespace each carry both subjects (group + provisioner
identity) with a single owner; and the install continues past this point — toward the next
component, and ideally `Ready`.
