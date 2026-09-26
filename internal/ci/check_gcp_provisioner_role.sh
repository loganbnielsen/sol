#!/usr/bin/env bash
# INFRA-045: GKE falls back from RBAC to IAM, so the provisioner's IAM role must
# contain only cluster discovery/credential access, never Kubernetes objects.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
source_file="${1:-$root/platform/cloud/gcp/cluster/main.tf}"

section="$(awk '
  /resource "google_project_iam_custom_role" "provisioner_cluster_access"/ { found=1 }
  found { print }
  found && /^}/ { exit }
' "$source_file")"

fail() {
  echo "check_gcp_provisioner_role: $*" >&2
  exit 1
}

[[ -n "$section" ]] || fail "custom provisioner role is missing"
if grep -q 'roles/container\.developer' "$source_file"; then
  fail "predefined roles/container.developer grant is present"
fi

for permission in \
  container.clusters.get \
  container.clusters.list \
  container.clusters.getCredentials \
  container.clusters.connect
do
  grep -q "\"$permission\"" <<<"$section" \
    || fail "custom role is missing $permission"
done

if grep -qE '"container\.(deployments|pods|namespaces|jobs|secrets|configMaps|clusterRoles|roleBindings)\.' <<<"$section"; then
  fail "custom role grants Kubernetes-object authority"
fi

# No extra container permissions may arrive under an innocent-looking resource
# name; keep the complete allowlist visible and reviewable here.
permission_count="$(grep -cE '^[[:space:]]*"container\.[A-Za-z.]+' <<<"$section")"
[[ "$permission_count" -eq 4 ]] \
  || fail "custom role contains a container permission outside the four-item allowlist"

echo "check_gcp_provisioner_role: provisioner IAM is discovery/credential-only"
