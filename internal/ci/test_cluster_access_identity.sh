#!/usr/bin/env bash
# Mutation test for the INFRA-046 offline guard.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
guard="$root/internal/ci/check_cluster_access_identity.sh"
policy="$root/cli/platform/infra/bootstrap/main.tf"
aws_root="$root/cli/platform/infra/aws/main.tf"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp "$policy" "$tmp/policy.tf"
cp "$aws_root" "$tmp/aws.tf"
"$guard" "$tmp/policy.tf" "$tmp/aws.tf" >/dev/null

sed -i '/"eks:AssociateAccessPolicy",/d' "$tmp/policy.tf"
if "$guard" "$tmp/policy.tf" "$tmp/aws.tf" >/dev/null 2>&1; then
  echo "test_cluster_access_identity: guard accepted a missing deny" >&2
  exit 1
fi

cp "$policy" "$tmp/policy.tf"
sed -i '/"eks:DescribeCluster", "eks:ListClusters"/s/]$/, "eks:CreateAccessEntry"]/' "$tmp/policy.tf"
if "$guard" "$tmp/policy.tf" "$tmp/aws.tf" >/dev/null 2>&1; then
  echo "test_cluster_access_identity: guard accepted a forbidden allow" >&2
  exit 1
fi

echo "test_cluster_access_identity: both policy mutations were rejected"
