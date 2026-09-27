#!/usr/bin/env bash
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

permission_count="$(grep -cE '^[[:space:]]*"container\.[A-Za-z.]+' <<<"$section")"
[[ "$permission_count" -eq 4 ]] \
  || fail "custom role contains a container permission outside the four-item allowlist"

echo "check_gcp_provisioner_role: provisioner IAM is discovery/credential-only"
