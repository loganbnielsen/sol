# The named AWS provisioner authenticates through its EKS access entry as this
# group. Namespaced platform mutations are bound only inside platform namespaces;
# ordinary application namespaces receive no binding.
resource "kubernetes_cluster_role" "platform_provisioner_namespaced" {
  metadata { name = "sol-platform-provisioner-namespaced" }
  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["*"]
  }
}

locals {
  platform_namespaces = toset(concat(
    ["cert-manager", "ingress-nginx", "argocd", "redpanda", "monitoring"],
    var.install_postgresql ? ["postgresql"] : [],
  ))
}

resource "kubernetes_role_binding" "platform_provisioner" {
  for_each = local.platform_namespaces
  metadata {
    name      = "sol-platform-provisioner"
    namespace = each.key
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.platform_provisioner_namespaced.metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "sol:platform-provisioners"
    api_group = "rbac.authorization.k8s.io"
  }
  depends_on = [
    kubernetes_namespace.cert_manager, kubernetes_namespace.ingress_nginx,
    kubernetes_namespace.argocd, kubernetes_namespace.redpanda,
    kubernetes_namespace.postgresql, kubernetes_namespace.monitoring,
  ]
}

# Cluster-wide platform installation is inherently highly privileged: Helm
# charts need CRDs/RBAC/webhooks and the platform owns StorageClasses and
# ClusterIssuers. Namespaced workload resources are deliberately omitted.
resource "kubernetes_cluster_role" "platform_provisioner_cluster" {
  metadata { name = "sol-platform-provisioner-cluster" }
  rule {
    api_groups = [""]
    resources  = ["namespaces", "nodes", "persistentvolumes"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
    verbs      = ["*"]
  }
  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses", "csidrivers", "csinodes"]
    verbs      = ["*"]
  }
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["clusterroles", "clusterrolebindings"]
    # Deliberately omit the RBAC-only bind/escalate verbs. Kubernetes' own
    # privilege-escalation prevention still permits chart RBAC whose grants
    # are already contained by this provisioner's effective permissions.
    verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["admissionregistration.k8s.io"]
    resources  = ["mutatingwebhookconfigurations", "validatingwebhookconfigurations"]
    verbs      = ["*"]
  }
  rule {
    api_groups = ["cert-manager.io"]
    resources  = ["clusterissuers"]
    verbs      = ["*"]
  }
  rule {
    api_groups = ["scheduling.k8s.io", "apiregistration.k8s.io"]
    resources  = ["priorityclasses", "apiservices"]
    verbs      = ["*"]
  }
}

# ── GCP: the same authorities, held by a Google identity ────────────────────
#
# AWS puts the named provisioner in the `sol:platform-provisioners` group through
# its EKS access entry, and every binding above is expressed against that group.
# GKE has no access-entry equivalent, and without Google Workspace there is no
# IAM->group mapping either: an out-of-cluster Google identity authenticates to
# the API server as itself. So the same two ClusterRoles are bound to that
# identity directly.
#
# What is shared is the authority model -- a named provisioner with exactly these
# rights, no more -- and what differs is how a cloud identity is attached to it.
# Binding the group *and* the identity conditionally would be the cosmetic
# version; this is the one the provider actually supports.
locals {
  gcp_provisioner = var.gcp_provisioner_service_account
}

resource "kubernetes_cluster_role_binding" "platform_provisioner_cluster_gcp" {
  count = local.gcp_provisioner == "" ? 0 : 1

  metadata { name = "sol-platform-provisioner-cluster" }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.platform_provisioner_cluster.metadata[0].name
  }
  subject {
    kind      = "User"
    name      = local.gcp_provisioner
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "kubernetes_role_binding" "platform_provisioner_gcp" {
  for_each = local.gcp_provisioner == "" ? toset([]) : local.platform_namespaces

  metadata {
    name      = "sol-platform-provisioner"
    namespace = each.key
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.platform_provisioner_namespaced.metadata[0].name
  }
  subject {
    kind      = "User"
    name      = local.gcp_provisioner
    api_group = "rbac.authorization.k8s.io"
  }
  depends_on = [
    kubernetes_namespace.cert_manager, kubernetes_namespace.ingress_nginx,
    kubernetes_namespace.argocd, kubernetes_namespace.redpanda,
    kubernetes_namespace.postgresql, kubernetes_namespace.monitoring,
  ]
}

# The install window, and only the install window. This is the GCP realization of
# the same semantic AWS realizes with `provisioner_bootstrap_admin` on an EKS
# access entry: the privilege the install needs (charts create CRDs, webhooks and
# cluster-scoped objects that the steady-state provisioner deliberately cannot)
# exists while Sol is installing and is removed before Ready. Same variable name,
# same lifecycle, different object -- because the authority is provider-shaped and
# the *invariant* is not.
resource "kubernetes_cluster_role_binding" "platform_provisioner_bootstrap_admin" {
  count = var.provisioner_bootstrap_admin && local.gcp_provisioner != "" ? 1 : 0

  metadata { name = "sol-platform-provisioner-bootstrap-admin" }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "User"
    name      = local.gcp_provisioner
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "kubernetes_cluster_role_binding" "platform_provisioner_cluster" {
  metadata { name = "sol-platform-provisioner-cluster" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.platform_provisioner_cluster.metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "sol:platform-provisioners"
    api_group = "rbac.authorization.k8s.io"
  }
}
