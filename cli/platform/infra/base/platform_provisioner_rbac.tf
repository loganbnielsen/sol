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
