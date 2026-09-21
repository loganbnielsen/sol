#!/usr/bin/env bash
set -euo pipefail

# DEC-039 / FND-0020: establish the qualification-only transport capability.
#
# Run by the qualification harness, never by `sol cloud apply`. Idempotent.
#
#   ./establish.sh <cluster-name> <iam-role-name> [region] [kubectl-context]
#
# The IAM role is given only what it needs to obtain a kubeconfig for this cluster
# (DescribeCluster/ListClusters); the Kubernetes half of its authority is the
# `sol:qualifiers` group membership plus the ClusterRole in transport.yaml. The
# manifest is applied with a context that already has cluster-admin in the platform
# (the qualification cluster-access identity), which is why the context is explicit
# rather than whatever happens to be current -- the kubeconfig aliasing hazard.

cluster="${1:?usage: establish.sh <cluster-name> <iam-role-name> [region] [context]}"
role="${2:?usage: establish.sh <cluster-name> <iam-role-name> [region] [context]}"
region="${3:-us-east-1}"
context="${4:-}"

account="$(aws sts get-caller-identity --query Account --output text)"
arn="arn:aws:iam::${account}:role/${role}"
here="$(cd "$(dirname "$0")" && pwd)"

echo "qualification transport: cluster=${cluster} role=${role} region=${region}"

# ── the IAM half: enough to obtain a kubeconfig, nothing more ────────────────
# Trust is account-scoped for simplicity: this role exists only in a qualification
# account, and every qualification identity there is already administrator-equivalent.
# It is not a pattern to copy into a customer environment, which is why the manifest
# lives outside the production roots and the guard asserts nothing references it.
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

# ── the Kubernetes half: group membership, no access policy ──────────────────
if aws eks describe-access-entry --cluster-name "$cluster" --principal-arn "$arn" >/dev/null 2>&1; then
  echo "  access entry already exists"
else
  aws eks create-access-entry \
    --cluster-name "$cluster" \
    --principal-arn "$arn" \
    --kubernetes-groups sol:qualifiers >/dev/null
  echo "  created access entry with group sol:qualifiers"
fi

# ── the grant ────────────────────────────────────────────────────────────────
if [ -n "$context" ]; then
  kubectl --context "$context" apply -f "$here/transport.yaml"
else
  kubectl apply -f "$here/transport.yaml"
fi

echo "qualification transport established. Verify with:"
echo "  aws eks update-kubeconfig --name ${cluster} --alias ${cluster}-qualifier --role-arn ${arn}"
echo "  kubectl --context ${cluster}-qualifier auth can-i create pods/portforward -n <app-namespace>   # yes"
echo "  kubectl --context ${cluster}-qualifier auth can-i delete pods            -n <app-namespace>   # no"
