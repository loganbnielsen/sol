#!/usr/bin/env bash
# Mutation self-test for check_kubernetes_object_ownership.sh (FND-0061).
#
# The strongest case is the first: the two declarations that actually failed a live platform
# apply (RoleBindings named sol-platform-provisioner, then the ClusterRoleBinding pair) must be
# rejected. If this ever goes green on that shape, the guard has stopped protecting anything.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$repo_root/internal/ci/check_kubernetes_object_ownership.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

mkcase() { # mkcase <name> -> echoes the temp root, with the real platform tree copied in
  local name="$1" root="$scratch/$name"
  mkdir -p "$root/platform/cloud"
  cp -r "$repo_root/platform/cloud/modules" "$root/platform/cloud/modules"
  mkdir -p "$root/platform/cloud/aws-platform-root"
  cp -r "$repo_root/platform/cloud/aws/platform" "$root/platform/cloud/aws-platform-root/platform"
  printf '%s' "$root"
}

reject() { # reject <name>  (a python mutation script on stdin; argv[1] is the case root)
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
  echo "  rejected: $name -- $(rg -m1 '^FAIL' "$scratch/$name.out" || head -1 "$scratch/$name.out")"
}

accept() { # accept <name> [<expected substring>]
  local name="$1" expect="${2:-}" root out
  root="$(mkcase "$name")"
  out="$scratch/$name.out"
  if ! "$guard" "$root" >"$out" 2>&1; then
    echo "FAIL: the guard rejected the '$name' case:" >&2
    cat "$out" >&2
    exit 1
  fi
  if [ -n "$expect" ] && ! rg -qF "$expect" "$out"; then
    echo "FAIL: the '$name' case did not report '$expect':" >&2
    cat "$out" >&2
    exit 1
  fi
  echo "  accepted: $name${expect:+ (reported: $expect)}"
}

mutate() { # mutate <name> [<expected substring>]  -- the mutation must be accepted
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
  if [ -n "$expect" ] && ! rg -qF "$expect" "$out"; then
    echo "FAIL: the '$name' case did not report '$expect':" >&2
    cat "$out" >&2
    exit 1
  fi
  echo "  accepted: $name${expect:+ (reported: $expect)}"
}

RBAC='platform/cloud/modules/platform/platform_provisioner_rbac.tf'

echo "check_kubernetes_object_ownership.sh mutations"

# 1. The RoleBinding collision FND-0061 hit live: a second resource writing the same Kubernetes
#    name in the same namespaces (the shape the fix removed).
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

# 2. The second pair from the same defect: the cluster-scoped binding, declared twice.
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

# 3. Two resources whose namespace *expressions* differ cannot be decided statically: reported,
#    not silently passed over, and not failed either.
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

# 4. The declared exception, said out loud on both blocks: accepted.
mutate deliberate-both-marked <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'platform/cloud/modules/platform/platform_provisioner_rbac.tf'
s = p.read_text()
s = s.replace('''  # One Kubernetes object, one Terraform owner (FND-0061).''',
              '''  # same-object-owner: mutation fixture for the declared exception.
  # One Kubernetes object, one Terraform owner (FND-0061).''', 1)
s += '''
resource "kubernetes_role_binding" "also_owns_it" {
  # same-object-owner: mutation fixture for the declared exception.
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

# 5. The exception claimed by only one side is not an exception.
reject deliberate-one-side-only <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'platform/cloud/modules/platform/platform_provisioner_rbac.tf'
s = p.read_text()
s += '''
resource "kubernetes_role_binding" "also_owns_it" {
  # same-object-owner: mutation fixture, deliberately only on this block.
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

# 6. Same name, genuinely different namespaces: not a collision.
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

# 7. Different kinds with the same name are different objects.
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

# 8. A name the check cannot resolve is recorded, not failed.
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
