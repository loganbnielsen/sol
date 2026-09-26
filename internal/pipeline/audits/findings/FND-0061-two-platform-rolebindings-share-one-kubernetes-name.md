# FND-0061 — Two platform RBAC resources share one Kubernetes RoleBinding name, so the full platform apply fails with `already exists` on a fresh GCP target

- **Classification:** `VERIFIED_DEFECT` (live: GCP Attempt 11's frozen bundle; the two conflicting
  declarations are in the repository and the collision is deterministic for a fresh GCP target)
- **State:** `OPEN`
- **First identified:** 2026-09-26, GCP Attempt 11 (`main @ 17afc4b2`) — exposed only because
  FND-0060's fix let the install get past cert-manager for the first time
- **Provider:** GCP in practice (`platform_provisioner_gcp` is empty when `local.gcp_provisioner`
  is empty, so the AWS path does not declare it); not exercised on AWS this run
- **Derived ticket:** `INFRA-089`
- **Evidence class:** `LIVE` (bundle `/tmp/sol-gcp-qual-11`)

## The defect (FACT)

`platform/cloud/modules/platform/platform_provisioner_rbac.tf` declares two `kubernetes_role_binding`
resources over the same namespace set, both writing **the same Kubernetes object name**:

```hcl
resource "kubernetes_role_binding" "platform_provisioner" {          # line 20
  for_each = local.platform_namespaces
  metadata { name = "sol-platform-provisioner" }                      # line 23
  role_ref { … name = kubernetes_cluster_role.platform_provisioner_namespaced.metadata[0].name }
  subject { kind = "Group"; name = "sol:platform-provisioners" }      # line 33
}

resource "kubernetes_role_binding" "platform_provisioner_gcp" {       # line 122
  for_each = local.gcp_provisioner == "" ? toset([]) : local.platform_namespaces
  metadata { name = "sol-platform-provisioner" }                      # line 126
  role_ref { … name = kubernetes_cluster_role.platform_provisioner_namespaced.metadata[0].name }
  subject { kind = "ServiceAccount"; name = local.gcp_provisioner }   # line 136
}
```

They differ only in subject. On a fresh GCP target the first one is created during the **targeted**
prerequisites step and the second one cannot be created afterwards.

## The observed failure (FACT)

```
[platform-prerequisites-apply] ok (143.7s)     ← -target includes …kubernetes_role_binding.platform_provisioner
[platform-apply] FAILED (201.6s)
  Error: rolebindings.rbac.authorization.k8s.io "sol-platform-provisioner" already exists
    with module.platform.kubernetes_role_binding.platform_provisioner_gcp["redpanda"]
    (and ["ingress-nginx"], ["monitoring"], ["cert-manager"], ["argocd"])
[provisioner-bootstrap-access-remove] ok (10.2s)   ← install window closed on the failure path
```

The frozen pre-teardown state carries `kubernetes_role_binding.platform_provisioner` and **not** the
`…platform_provisioner_gcp[…]` addresses, which is exactly the shape the error predicts.

## Why this is a defect and not a run artifact

- Both resources are declared unconditionally in the module (the `_gcp` one only when a GCP
  provisioner is configured), so the collision is deterministic for a fresh GCP target whose
  prerequisites step runs first.
- It was **invisible until now** because cert-manager's release failed *inside* the prerequisites
  step (Attempts 4/5/8/9/10), so the full apply never ran. FND-0060's fix exposed it — which is the
  intended way for the next blocker to appear, not a regression from that fix.
- `INFERENCE`: on a target where the prerequisites step does not run before the full apply, the
  first resource to be created would win and the other would still fail — i.e. the ordering changes
  which error appears, not whether one does.

## What would settle the fix (a design decision, not taken here)

The two subjects appear to be *both* wanted — the human group and the provisioner service account
both need the namespaced role — so the defect is the shared Kubernetes name rather than either
subject. Candidate directions, none approved: one resource with both subjects; distinct names; or
one resource plus explicit `moved`/import handling if the intent is a rename. Choosing is a product
design decision, deliberately left out of the run that found it.

## Non-goals recorded

No remediation during Attempt 11 (no state surgery, no `terraform import`, no Helm/RBAC edit, no
re-run of the failed step). The failed-install destruction path worked: the window closed, the
authority bracket ran, both roots ended empty, and the provider inventory reports absent.
