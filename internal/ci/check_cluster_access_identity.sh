#!/usr/bin/env bash
# INFRA-046: pin the AWS cloud-provisioning / steady-state cluster-access split.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
policy_file="${1:-$root/cli/platform/infra/bootstrap/main.tf}"
aws_root="${2:-$root/cli/platform/infra/aws/main.tf}"

section="$(awk '
  /data "aws_iam_policy_document" "cluster_access"/ { found=1 }
  found { print }
  found && /^}/ { exit }
' "$policy_file")"

fail() {
  echo "check_cluster_access_identity: $*" >&2
  exit 1
}

[[ -n "$section" ]] || fail "cluster_access policy is missing"
grep -q '"eks:DescribeCluster"' <<<"$section" \
  || fail "steady-state identity cannot discover the cluster"

for action in \
  'eks:CreateAccessEntry' \
  'eks:DeleteAccessEntry' \
  'eks:UpdateAccessEntry' \
  'eks:AssociateAccessPolicy' \
  'eks:DisassociateAccessPolicy' \
  'iam:\*'
do
  grep -q "\"$action\"" <<<"$section" \
    || fail "steady-state explicit deny is missing $action"
done

if awk '
  /sid[[:space:]]*=[[:space:]]*"DiscoverCluster"/ { allow=1 }
  allow && /sid[[:space:]]*=/ && !/DiscoverCluster/ { allow=0 }
  allow && /"(eks:(Create|Update|Delete|Associate|Disassociate)|iam:)/ { bad=1 }
  END { exit bad ? 0 : 1 }
' <<<"$section"
then
  fail "steady-state allow grants access-entry, policy-association, or IAM mutation"
fi

grep -q 'var.cluster_access_role_arn' "$aws_root" \
  || fail "EKS access entry is not owned by cluster_access_role_arn"

echo "check_cluster_access_identity: provisioning and steady-state identities are structurally separate"
