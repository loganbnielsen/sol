import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "internal/ci/check_kubernetes_object_ownership.py"
RBAC = "platform/cloud/modules/platform/platform_provisioner_rbac.tf"

CASES = [
    ("rolebinding-collision", "fail", '', """
resource "kubernetes_role_binding" "platform_provisioner_gcp" {
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
    kind      = "User"
    name      = "provisioner@example.iam.gserviceaccount.com"
    api_group = "rbac.authorization.k8s.io"
  }
}
"""),
    ("clusterrolebinding-collision", "fail", '', """
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
"""),
    ("same-name-different-namespace-expression", "pass", 'cannot decide whether those resolve', """
resource "kubernetes_role_binding" "sometimes" {
  for_each = toset(["monitoring"])
  metadata {
    name      = "sol-platform-provisioner"
    namespace = each.value
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
}
"""),
    ("second-owner", "fail", '', """
resource "kubernetes_role_binding" "also_owns_it" {
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
}
"""),
    ("same-name-different-namespaces", "pass", '', """
resource "kubernetes_config_map" "a" {
  metadata {
    name      = "shared-name"
    namespace = "cert-manager"
  }
}
resource "kubernetes_config_map" "b" {
  metadata {
    name      = "shared-name"
    namespace = "monitoring"
  }
}
"""),
    ("same-name-different-kinds", "pass", '', """
resource "kubernetes_role" "shared" {
  metadata {
    name      = "shared-kind-name"
    namespace = "cert-manager"
  }
}
resource "kubernetes_cluster_role" "shared" {
  metadata { name = "shared-kind-name" }
}
"""),
    ("dynamic-name-case", "pass", 'cannot resolve statically', """
resource "kubernetes_secret" "generated" {
  metadata {
    generate_name = "generated-"
    namespace     = "cert-manager"
  }
}
"""),
    ("real-tree", "pass", "", ""),
]


def tree(scratch, name):
    root = scratch / name
    shutil.copytree(REPO / "platform/cloud/modules", root / "platform/cloud/modules")
    shutil.copytree(REPO / "platform/cloud/aws/platform", root / "platform/cloud/aws-platform-root/platform")
    return root


def main():
    print("check_kubernetes_object_ownership mutations")
    with tempfile.TemporaryDirectory() as scratch:
        for name, want, expect, snippet in CASES:
            root = tree(Path(scratch), name)
            with open(root / RBAC, "a", encoding="utf-8") as f:
                f.write(snippet)
            run = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
            output = run.stdout + run.stderr
            got = "pass" if run.returncode == 0 else "fail"
            if got != want:
                sys.exit(f"FAIL: the guard's verdict on '{name}' was {got}, expected {want}:\n{output}")
            if expect and expect not in output:
                sys.exit(f"FAIL: the '{name}' case did not report '{expect}':\n{output}")
            first = next((l for l in output.splitlines() if l.startswith("FAIL")), "")
            print(f"  {'rejected' if want == 'fail' else 'accepted'}: {name}" + (f" -- {first}" if first else "") + (f" (reported: {expect})" if expect else ""))
    print("check_kubernetes_object_ownership: all mutations rejected, accepted cases accepted")


main()
