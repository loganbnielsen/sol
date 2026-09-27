#!/usr/bin/env bash
set -euo pipefail

cluster="${1:?usage: establish.sh <cluster-name> <iam-role-name> [region] [context]}"
role="${2:?usage: establish.sh <cluster-name> <iam-role-name> [region] [context]}"
region="${3:-us-east-1}"
context="${4:-}"

account="$(aws sts get-caller-identity --query Account --output text)"
arn="arn:aws:iam::${account}:role/${role}"
here="$(cd "$(dirname "$0")" && pwd)"

echo "qualification transport: cluster=${cluster} role=${role} region=${region}"

if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
  trust="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::${account}:root\"},\"Action\":\"sts:AssumeRole\"}]}"
  aws iam create-role \
    --role-name "$role" \
    --description "Sol qualification-only transport principal (DEC-039). Not production." \
    --assume-role-policy-document "$trust" >/dev/null
  echo "  created IAM role ${role}"
else
  echo "  IAM role ${role} already exists"
fi

aws iam put-role-policy \
  --role-name "$role" \
  --policy-name sol-qualifier-transport \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Sid":"ReachTheCluster","Effect":"Allow","Action":["eks:ListClusters","eks:DescribeCluster"],"Resource":"*"}]}' >/dev/null
echo "  policy sol-qualifier-transport attached (eks:ListClusters, eks:DescribeCluster)"

if aws eks describe-access-entry --cluster-name "$cluster" --principal-arn "$arn" >/dev/null 2>&1; then
  echo "  access entry already exists"
else
  aws eks create-access-entry \
    --cluster-name "$cluster" \
    --principal-arn "$arn" \
    --kubernetes-groups sol:qualifiers >/dev/null
  echo "  created access entry with group sol:qualifiers"
fi

admin_policy="arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
close_window() {
  aws eks disassociate-access-policy \
    --cluster-name "$cluster" \
    --principal-arn "$arn" \
    --policy-arn "$admin_policy" \
    --access-scope type=cluster >/dev/null 2>&1 || true
}
trap close_window EXIT

echo "  opening a temporary establishment window (cluster-admin association)"
aws eks associate-access-policy \
  --cluster-name "$cluster" \
  --principal-arn "$arn" \
  --policy-arn "$admin_policy" \
  --access-scope type=cluster >/dev/null

for _ in 1 2 3 4 5 6; do
  aws eks update-kubeconfig --name "$cluster" --alias "${cluster}-qualifier" --role-arn "$arn" >/dev/null 2>&1
  if kubectl --context "${cluster}-qualifier" apply -f "$here/transport.yaml" >/dev/null 2>&1; then
    break
  fi
  sleep 10
done

kubectl --context "${cluster}-qualifier" get clusterrole sol-qualifier-transport >/dev/null 2>&1 ||
  { echo "  could not apply the transport manifest" >&2; exit 1; }

close_window
trap - EXIT
echo "  applied transport.yaml, and closed the window"

echo "qualification transport established. Verify with:"
echo "  aws eks update-kubeconfig --name ${cluster} --alias ${cluster}-qualifier --role-arn ${arn}"
echo "  kubectl --context ${cluster}-qualifier auth can-i create pods/portforward -n <app-namespace>   # yes"
echo "  kubectl --context ${cluster}-qualifier auth can-i delete pods            -n <app-namespace>   # no"
