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
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["clusterroles"]
    # DEC-038 / INFRA-057: enumerated, never wildcarded. The substrate step runs
    # as the deploy identity, and Kubernetes lets a RoleBinding grant permissions
    # its creator lacks only when the creator holds `bind` on that specific
    # ClusterRole -- so every ClusterRole the substrate binds must be listed here.
    # A live run failed on exactly this: the operator's read-only binding could
    # not be created because sol-operator-diagnostics was not bindable. The fix is
    # this second name -- not `escalate`, which would permit granting anything,
    # and not giving the deploy identity the operator's diagnostic permissions,
    # which would dissolve the boundary DEC-038 draws.
    resource_names = [
      kubernetes_cluster_role.sol_deploy.metadata[0].name,
      kubernetes_cluster_role.sol_operator_diagnostics.metadata[0].name,
    ]
    verbs = ["bind"]
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

# INFRA-043: the workspace boundary lease is deliberately kept in `default`
# so deploy and rollback coordinate across every application namespace in the
# workspace.  The ordinary sol-deploy Role is only bound inside application
# namespaces, so it cannot authorize this object.  Keep the exception separate
# and namespaced: it grants only ConfigMap operations, only in `default`, and
# only the four verbs issued by Sol_cli_boundary_lease.
#
# Kubernetes does not honor resourceNames for `create` authorization (the name
# is not available to the authorizer for that request), so `create` cannot be
# narrowed to sol-boundary-lease-* in RBAC.  Reads and subsequent mutations are
# nevertheless client-scoped to that exact generated name, and the offline
# production-infra check below pins the grant to the issued operation set.
resource "kubernetes_role" "sol_boundary_lease" {
  metadata {
    name      = "sol-boundary-lease"
    namespace = "default"
  }

  # `create` cannot use resource_names: Kubernetes authorizes create before a
  # named object exists.  Keep it in its own rule so no other verb inherits
  # that unavoidable limitation.
  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["create"]
  }

  # Terraform cannot know workspace names at platform-install time.  The
  # boundary-lease implementation supplies the generated name on every one of
  # these requests; unlike create, these verbs can be name-scoped if/when the
  # workspace inventory becomes an input to the platform module.
  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["get", "update", "delete"]
  }
}

resource "kubernetes_role_binding" "sol_boundary_lease" {
  metadata {
    name      = "sol-boundary-lease"
    namespace = "default"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.sol_boundary_lease.metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "sol:deployers"
    api_group = "rbac.authorization.k8s.io"
  }
}
