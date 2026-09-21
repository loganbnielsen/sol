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

# ── the grant: applied inside a temporary establishment window ───────────────
#
# Creating cluster-scoped RBAC requires cluster-scoped RBAC, and no standing identity
# has it: the platform was installed with a temporary privileged installation
# authority that was de-escalated afterwards (ADR 0003), leaving `cluster-access` with
# platform reads and no cluster-RBAC write. So the harness opens the same kind of
# window the installation used -- associate cluster-admin, apply the narrow manifest,
# disassociate -- and what *remains* is transport and addressing only.
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

# Propagate, then apply with the qualifier's own credentials so the window is the
# only thing that made it possible -- not an adjacent admin context.
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

# The context named above now authenticates as the qualifier, whose standing
# authority is the group membership plus sol-qualifier-transport.

echo "qualification transport established. Verify with:"
echo "  aws eks update-kubeconfig --name ${cluster} --alias ${cluster}-qualifier --role-arn ${arn}"
echo "  kubectl --context ${cluster}-qualifier auth can-i create pods/portforward -n <app-namespace>   # yes"
echo "  kubectl --context ${cluster}-qualifier auth can-i delete pods            -n <app-namespace>   # no"
