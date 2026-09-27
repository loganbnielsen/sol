#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
guard="$root/internal/ci/check_gcp_provisioner_role.py"
source_file="$root/platform/cloud/gcp/cluster/main.tf"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp "$source_file" "$tmp/main.tf"
python3 "$guard" "$tmp/main.tf" >/dev/null

sed -i 's/google_project_iam_custom_role.provisioner_cluster_access.name/"roles\/container.developer"/' "$tmp/main.tf"
if python3 "$guard" "$tmp/main.tf" >/dev/null 2>&1; then
  echo "test_gcp_provisioner_role: guard accepted roles/container.developer" >&2
  exit 1
fi

cp "$source_file" "$tmp/main.tf"
sed -i '/"container.clusters.connect",/a\    "container.deployments.create",' "$tmp/main.tf"
if python3 "$guard" "$tmp/main.tf" >/dev/null 2>&1; then
  echo "test_gcp_provisioner_role: guard accepted workload mutation" >&2
  exit 1
fi

echo "test_gcp_provisioner_role: both authority mutations were rejected"
