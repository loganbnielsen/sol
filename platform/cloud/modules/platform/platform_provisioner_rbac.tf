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
  # One Kubernetes object, one Terraform owner (FND-0061).
  #
  # Both subjects hold this same role, in these same namespaces, for the same lifetime: the
  # platform's. They differ only in how a cloud identity reaches the API server -- the AWS
  # provisioner arrives as a member of this group (its EKS access entry declares
  # `kubernetes_groups = ["sol:platform-provisioners"]`), while a GKE identity authenticates as
  # itself and belongs to no group Sol can name. Two subjects of one RoleBinding is exactly what
  # a RoleBinding is for.
  #
  # This was two resources until FND-0061: each declared one subject and both wrote *this*
  # Kubernetes object, so whichever applied second failed with `already exists` -- the GCP
  # provisioner's namespaced authority could never be created on a fresh target.
  subject {
    kind      = "Group"
    name      = "sol:platform-provisioners"
    api_group = "rbac.authorization.k8s.io"
  }
  dynamic "subject" {
    for_each = local.gcp_provisioner == "" ? [] : [local.gcp_provisioner]
    content {
      kind      = "User"
      name      = subject.value
      api_group = "rbac.authorization.k8s.io"
    }
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
# its EKS access entry, and every binding above carries that group. GKE has no
# access-entry equivalent, and without Google Workspace there is no IAM->group
# mapping either: an out-of-cluster Google identity authenticates to the API
# server as itself. So the same ClusterRoles carry that identity as an *additional
# subject on the same objects* -- same authority, same lifetime, one owner
# (FND-0061). An earlier note here called carrying both "the cosmetic version";
# that was a judgement about semantics, and it is the same authority either way,
# while two resources cannot own one Kubernetes object.
locals {
  gcp_provisioner = var.gcp_provisioner_service_account
}

resource "kubernetes_cluster_role_binding" "platform_provisioner_cluster" {
  metadata { name = "sol-platform-provisioner-cluster" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.platform_provisioner_cluster.metadata[0].name
  }
  # Same reasoning as the namespaced binding above: same role, same lifetime, one owner. This was
  # the second FND-0061 collision -- it never got to fail first, because the RoleBinding pair
  # failed in the same apply.
  subject {
    kind      = "Group"
    name      = "sol:platform-provisioners"
    api_group = "rbac.authorization.k8s.io"
  }
  dynamic "subject" {
    for_each = local.gcp_provisioner == "" ? [] : [local.gcp_provisioner]
    content {
      kind      = "User"
      name      = subject.value
      api_group = "rbac.authorization.k8s.io"
    }
  }
}
