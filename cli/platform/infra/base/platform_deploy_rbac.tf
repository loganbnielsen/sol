# AUDIT-072 / INFRA-025: the named AWS deploy principal authenticates through
# its EKS access entry (cli/platform/infra/aws) as Kubernetes group
# "sol:deployers". This ClusterRole grants nothing until bound -- unlike the
# platform provisioner's namespaced role (platform_provisioner_rbac.tf),
# which Terraform binds to a fixed, statically-known set of platform
# namespaces, deploy's namespaces are created dynamically per workspace
# (Sol_cli_substrate.ensure, called from `sol deploy`/`sol migrate apply`),
# so the RoleBinding itself is applied at runtime, per namespace, by Sol --
# not here. A ClusterRoleBinding would grant deploy these same verbs in
# platform namespaces too (the ingress controller's Deployment, Argo CD's
# Deployment, any platform Secret), which is exactly the boundary this ticket
# exists to prevent.
#
# Scoped to the resource kinds Sol's workload render (sol_cli_manifest_yaml.ml)
# actually produces, not a wildcard: Namespace and PersistentVolumeClaim are
# deliberately omitted (namespace creation belongs to the substrate step, not
# the deploy identity; PVC mutation is not part of the deploy/rollback/migrate
# surface today).
resource "kubernetes_cluster_role" "sol_deploy" {
  metadata { name = "sol-deploy" }

  rule {
    api_groups = [""]
    resources  = ["configmaps", "secrets", "serviceaccounts", "services"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["policy"]
    resources  = ["poddisruptionbudgets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses", "networkpolicies"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["argoproj.io"]
    resources  = ["rollouts"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["external-secrets.io"]
    resources  = ["externalsecrets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

# Bootstraps deploy's access to a brand-new application namespace. A
# namespace-scoped RoleBinding cannot itself grant permission to create the
# namespace or the RoleBinding that grants everything else -- Namespace is a
# cluster-scoped resource, and Kubernetes RBAC cannot authorize a
# RoleBinding/ClusterRoleBinding subject for a resource kind that
# RoleBindings can never cover, no matter which ClusterRole it references.
# This is therefore a separate, deliberately minimal, cluster-wide grant:
#
#   - "namespaces": get/list/watch/create only, never update/patch/delete, so
#     deploy can create a namespace that does not yet exist but can never
#     mutate one that already does -- including every platform namespace.
#     Sol_cli_substrate.ensure treats an "AlreadyExists" response to create
#     as success rather than calling `kubectl apply` (which would need
#     patch), so idempotent re-application never needs more than this.
#   - "rolebindings": get/list/watch/create only, same reasoning and same
#     idempotent-create pattern -- the RoleBinding's content never changes
#     after creation, so it never needs patch either.
#   - "clusterroles" "bind", restricted by resourceNames to exactly
#     "sol-deploy": Kubernetes' own RBAC escalation check requires the
#     "bind" verb (or already possessing every permission in the referenced
#     role) before a principal may create a RoleBinding that references a
#     ClusterRole. Scoping resourceNames means deploy can only ever bind
#     this one, specific, already-reviewed role -- never author a binding to
#     cluster-admin or anything else.
resource "kubernetes_cluster_role" "sol_deploy_bootstrap" {
  metadata { name = "sol-deploy-bootstrap" }

  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["get", "list", "watch", "create"]
  }
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["rolebindings"]
    verbs      = ["get", "list", "watch", "create"]
  }
  rule {
    api_groups     = ["rbac.authorization.k8s.io"]
    resources      = ["clusterroles"]
    resource_names = [kubernetes_cluster_role.sol_deploy.metadata[0].name]
    verbs          = ["bind"]
  }
}

resource "kubernetes_cluster_role_binding" "sol_deploy_bootstrap" {
  metadata { name = "sol-deploy-bootstrap" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.sol_deploy_bootstrap.metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "sol:deployers"
    api_group = "rbac.authorization.k8s.io"
  }
}
