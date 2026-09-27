resource "kubernetes_cluster_role" "sol_operator_diagnostics" {
  metadata { name = "sol-operator-diagnostics" }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "services", "events"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["cronjobs"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role" "sol_operator_namespaces" {
  metadata { name = "sol-operator-namespaces" }

  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding" "sol_operator_namespaces" {
  metadata { name = "sol-operator-namespaces" }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.sol_operator_namespaces.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "sol:operators"
    api_group = "rbac.authorization.k8s.io"
  }
}
