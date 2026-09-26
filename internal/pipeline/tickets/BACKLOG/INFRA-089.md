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

## Decision required: which shape the fix takes

The two subjects look like they are *both* wanted — the human group and the provisioner service
account both need the namespaced role — so the defect is the **shared Kubernetes name**, not either
subject. Candidate directions, none approved here:

1. **One resource, both subjects** — merge the two into a single `kubernetes_role_binding` with two
   `subject` blocks (which is what a RoleBinding supports natively), keeping the
   `gcp_provisioner == ""` gate as a conditional subject list.
2. **Distinct Kubernetes names** — two bindings, named apart, so both can exist.
3. **A rename with state handling** — if the intent was to replace one with the other, a `moved`
   block (or documented migration) is needed for existing targets, which this ticket must state.

Direction is a product/design decision, deliberately not taken during the run that found it, and
whichever direction is chosen needs an offline guard rather than a live run to prove the collision
is gone (the two declarations no longer produce one Kubernetes name).

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
