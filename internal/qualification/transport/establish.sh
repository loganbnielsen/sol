#!/usr/bin/env bash
set -euo pipefail

cluster="${1:?usage: establish.sh <cluster-name> <iam-role-name> [region] [namespace]}"
role="${2:?usage: establish.sh <cluster-name> <iam-role-name> [region] [namespace]}"
region="${3:-us-east-1}"
verify_ns="${4:-default}"

account="$(aws sts get-caller-identity --query Account --output text)"
arn="arn:aws:iam::${account}:role/${role}"
alias="${cluster}-qualifier"
here="$(cd "$(dirname "$0")" && pwd)"

echo "qualification transport: cluster=${cluster} role=${role} region=${region} namespace=${verify_ns}"

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

entry_exists() {
  aws eks describe-access-entry --cluster-name "$cluster" --principal-arn "$arn" >/dev/null 2>&1
}

create_narrow_entry() {
  if entry_exists; then
    echo "  access entry with group sol:qualifiers already exists"
    return 0
  fi
  aws eks create-access-entry \
    --cluster-name "$cluster" \
    --principal-arn "$arn" \
    --kubernetes-groups sol:qualifiers >/dev/null
  echo "  created access entry with group sol:qualifiers"
}

delete_entry() {
  aws eks delete-access-entry --cluster-name "$cluster" --principal-arn "$arn" >/dev/null 2>&1 || true
}

kubeconfig() {
  aws eks update-kubeconfig --name "$cluster" --alias "$alias" --role-arn "$arn" >/dev/null 2>&1
}

end_state=narrow
cleanup() {
  case "$end_state" in
    narrow)
      delete_entry
      create_narrow_entry || true
      ;;
    none)
      delete_entry
      ;;
  esac
}
trap cleanup EXIT

create_narrow_entry

admin_policy="arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

echo "  opening a temporary establishment window (cluster-admin association)"
aws eks associate-access-policy \
  --cluster-name "$cluster" \
  --principal-arn "$arn" \
  --policy-arn "$admin_policy" \
  --access-scope type=cluster >/dev/null

for _ in 1 2 3 4 5 6; do
  kubeconfig
  if kubectl --context "$alias" apply -f "$here/transport.yaml" >/dev/null 2>&1; then
    break
  fi
  sleep 10
done

kubectl --context "$alias" get clusterrole sol-qualifier-transport >/dev/null 2>&1 ||
  { echo "  could not apply the transport manifest" >&2; exit 1; }

echo "  closing the window by deleting the access entry and recreating it with only sol:qualifiers"
delete_entry
create_narrow_entry

end_state=none

probe_effective_surface() {
  kubeconfig
  local whoami
  whoami="$(kubectl --context "$alias" auth whoami -o json 2>/dev/null || true)"
  if ! printf '%s' "$whoami" | grep -q "$role"; then
    echo "  the context does not authenticate as ${role}; kubectl auth whoami said: ${whoami:-<no answer>}" >&2
    return 1
  fi
  if ! kubectl --context "$alias" get pods -n "$verify_ns" >/dev/null 2>&1; then
    echo "  the addressing grant is not effective: get pods -n ${verify_ns} was refused" >&2
    return 1
  fi
  local secrets
  secrets="$(kubectl --context "$alias" get secrets -n "$verify_ns" 2>&1 || true)"
  if ! printf '%s' "$secrets" | grep -qi forbidden; then
    echo "  the grant is broader than declared: get secrets -n ${verify_ns} did not report Forbidden. Observed: ${secrets:-<no output>}" >&2
    return 1
  fi
  if [ "$(kubectl --context "$alias" auth can-i create pods/portforward -n "$verify_ns" 2>/dev/null)" != "yes" ]; then
    echo "  pods/portforward is not permitted in ${verify_ns}" >&2
    return 1
  fi
  return 0
}

verify_attempts="${SOL_QUALIFIER_VERIFY_ATTEMPTS:-12}"
verify_interval="${SOL_QUALIFIER_VERIFY_INTERVAL_S:-15}"
case "$verify_attempts" in '' | *[!0-9]*)
  echo "  SOL_QUALIFIER_VERIFY_ATTEMPTS must be a positive integer" >&2
  exit 2
  ;;
esac
[ "$verify_attempts" -gt 0 ] || {
  echo "  SOL_QUALIFIER_VERIFY_ATTEMPTS must be a positive integer" >&2
  exit 2
}
case "$verify_interval" in '' | *[!0-9]*)
  echo "  SOL_QUALIFIER_VERIFY_INTERVAL_S must be a non-negative integer" >&2
  exit 2
  ;;
esac

verified=false
attempt=0
while [ "$attempt" -lt "$verify_attempts" ]; do
  attempt=$((attempt + 1))
  if probe_effective_surface; then
    verified=true
    break
  fi
  echo "  the effective surface is not yet the declared one; attempt ${attempt}/${verify_attempts}" >&2
  if [ "$attempt" -lt "$verify_attempts" ]; then
    sleep "$verify_interval"
  fi
done

if [ "$verified" != true ]; then
  echo "  refusing to leave a credential broader than its contract: removing the access entry" >&2
  exit 1
fi

end_state=narrow
trap - EXIT
echo "  verified the effective surface as ${role} in ${verify_ns}: pods readable, secrets Forbidden, pods/portforward permitted"

echo "qualification transport established. Verify with:"
echo "  aws eks update-kubeconfig --name ${cluster} --alias ${alias} --role-arn ${arn}"
echo "  kubectl --context ${alias} get pods -n ${verify_ns}                           # succeeds"
echo "  kubectl --context ${alias} get secrets -n ${verify_ns}                        # Forbidden"
echo "  kubectl --context ${alias} auth can-i create pods/portforward -n ${verify_ns}  # yes"
