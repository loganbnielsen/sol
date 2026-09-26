# ADR 0002 / DEC-038 / INFRA-057: the named AWS operator principal authenticates
# through its EKS access entry (platform/cloud/aws/cluster) as Kubernetes group
# "sol:operators". This is the identity that owns *production observation and
# diagnosis*; the boundary is provisioner (infrastructure mutation), publisher
# (artifact publication), deploy (application/release mutation), operator
# (observation and diagnosis).
#
# Every rule below is a read an existing read-only Sol command actually performs,
# rather than a generic "view" posture:
#
#   pods, pods/log   sol status, sol logs, rollout diagnosis
#   services         sol status (service addressing)
#   events           rollout diagnosis -- the explanation of *why* a pod is unwell
#   deployments      sol status (live image, rollout state)
#   cronjobs         sol status for a function primitive
#
# [get] and [list] only. Nothing in the read-only surface watches, so `watch` is
# deliberately absent. There is no mutating verb and no wildcard, and three
# omissions are deliberate:
#
#   - secrets: reading them is an inspection capability, not part of explaining
#     an unhealthy workload;
#   - pods/exec and pods/portforward: interactive debugging, not diagnosis. They
#     are excluded even though port-forward would have made a recent
#     investigation easier -- that is not a contract, and if a future command
#     needs them it must justify them on its own.
#
# Bound per application namespace at runtime (Sol_cli_substrate.ensure), like the
# deploy role: application namespaces are created dynamically, so a Terraform-time
# list cannot express them, and a ClusterRoleBinding would let the operator read
# workload evidence in platform namespaces too.
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

# `sol status` asks whether a namespace exists before reporting on it, and
# Namespace is cluster-scoped, so no namespaced RoleBinding can ever cover it.
# This is therefore a separate, deliberately minimal, cluster-wide grant: get and
# list on namespaces only. It carries no workload resource and nothing writable.
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
