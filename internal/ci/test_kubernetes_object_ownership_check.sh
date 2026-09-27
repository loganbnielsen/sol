#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$repo_root/internal/ci/check_kubernetes_object_ownership.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

mkcase() {
  local name="$1" root="$scratch/$name"
  mkdir -p "$root/platform/cloud"
  cp -r "$repo_root/platform/cloud/modules" "$root/platform/cloud/modules"
  mkdir -p "$root/platform/cloud/aws-platform-root"
  cp -r "$repo_root/platform/cloud/aws/platform" "$root/platform/cloud/aws-platform-root/platform"
  printf '%s' "$root"
}

reject() {
  local name="$1" root rc mutfile
  root="$(mkcase "$name")"
  mutfile="$scratch/$name.mutation.py"
  cat >"$mutfile"
  python3 "$mutfile" "$root"
  set +e
  "$guard" "$root" >"$scratch/$name.out" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: the guard accepted the '$name' mutation:" >&2
    cat "$scratch/$name.out" >&2
    exit 1
  fi
  echo "  rejected: $name -- $(grep -m1 '^FAIL' "$scratch/$name.out" || head -1 "$scratch/$name.out")"
}

accept() {
  local name="$1" expect="${2:-}" root out
  root="$(mkcase "$name")"
  out="$scratch/$name.out"
  if ! "$guard" "$root" >"$out" 2>&1; then
    echo "FAIL: the guard rejected the '$name' case:" >&2
    cat "$out" >&2
    exit 1
  fi
  if [ -n "$expect" ] && ! grep -qF -- "$expect" "$out"; then
    echo "FAIL: the '$name' case did not report '$expect':" >&2
    cat "$out" >&2
    exit 1
  fi
  echo "  accepted: $name${expect:+ (reported: $expect)}"
}

mutate() {
  local name="$1" expect="${2:-}"
  local root
  root="$(mkcase "$name")"
  local mutfile="$scratch/$name.mutation.py"
  cat >"$mutfile"
  python3 "$mutfile" "$root"
  local out="$scratch/$name.out"
  if ! "$guard" "$root" >"$out" 2>&1; then
    echo "FAIL: the guard rejected the '$name' case:" >&2
    cat "$out" >&2
    exit 1
  fi
  if [ -n "$expect" ] && ! grep -qF -- "$expect" "$out"; then
    echo "FAIL: the '$name' case did not report '$expect':" >&2
    cat "$out" >&2
    exit 1
  fi
  echo "  accepted: $name${expect:+ (reported: $expect)}"
}

RBAC='platform/cloud/modules/platform/platform_provisioner_rbac.tf'

echo "check_kubernetes_object_ownership.sh mutations"

reject rolebinding-collision <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'platform/cloud/modules/platform/platform_provisioner_rbac.tf'
s = p.read_text()
s += '''
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
'''
p.write_text(s)
PY

reject clusterrolebinding-collision <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'platform/cloud/modules/platform/platform_provisioner_rbac.tf'
s = p.read_text()
s += '''
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
'''
p.write_text(s)
PY

mutate same-name-different-namespace-expression 'cannot decide whether those resolve' <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'platform/cloud/modules/platform/platform_provisioner_rbac.tf'
s = p.read_text()
s += '''
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
'''
p.write_text(s)
PY

reject second-owner <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'platform/cloud/modules/platform/platform_provisioner_rbac.tf'
s = p.read_text()
s += '''
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
'''
p.write_text(s)
PY

mutate same-name-different-namespaces <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'platform/cloud/modules/platform/platform_provisioner_rbac.tf'
s = p.read_text()
s += '''
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
'''
p.write_text(s)
PY

mutate same-name-different-kinds <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'platform/cloud/modules/platform/platform_provisioner_rbac.tf'
s = p.read_text()
s += '''
resource "kubernetes_role" "shared" {
  metadata {
    name      = "shared-kind-name"
    namespace = "cert-manager"
  }
}
resource "kubernetes_cluster_role" "shared" {
  metadata { name = "shared-kind-name" }
}
'''
p.write_text(s)
PY

mutate dynamic-name-case 'cannot resolve statically' <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'platform/cloud/modules/platform/platform_provisioner_rbac.tf'
s = p.read_text()
s += '''
resource "kubernetes_secret" "generated" {
  metadata {
    generate_name = "generated-"
    namespace     = "cert-manager"
  }
}
'''
p.write_text(s)
PY

accept real-tree

echo "check_kubernetes_object_ownership.sh: all mutations rejected, accepted cases accepted"
