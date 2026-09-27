#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(git rev-parse --show-toplevel)}"

role="$root/platform/cloud/modules/platform/platform_operator_rbac.tf"
aws_main="$root/platform/cloud/aws/cluster/main.tf"
aws_vars="$root/platform/cloud/aws/cluster/variables.tf"
rbac_doc="$root/cli/lib/workspace/sol_cli_manifest_yaml.ml"
substrate="$root/cli/lib/deploy/sol_cli_substrate.ml"

fail() {
  echo "check_operator_diagnostics: $1" >&2
  exit 1
}

for f in "$role" "$aws_main" "$aws_vars" "$rbac_doc" "$substrate"; do
  [ -f "$f" ] || fail "missing $f"
done

if grep -E 'verbs[[:space:]]*=' "$role" | grep -Eq '"(create|update|patch|delete|deletecollection)"'; then
  fail "the operator's role grants a mutating verb; it owns observation only"
fi

if grep -Eq 'verbs[[:space:]]*=[[:space:]]*\["\*"\]' "$role"; then
  fail "the operator's role uses a wildcard verb"
fi

if grep -E 'resources[[:space:]]*=' "$role" | grep -Eq '"secrets"'; then
  fail "the operator's role grants secrets: inspection is not diagnosis"
fi

if grep -E 'resources[[:space:]]*=' "$role" | grep -Eq 'pods/(exec|portforward|attach)'; then
  fail "the operator's role grants interactive debugging; DEC-038 excludes it from the diagnostic surface"
fi

grep -q 'variable "operator_role_arn"' "$aws_vars" ||
  fail "operator_role_arn is not a variable of the AWS root"

entry=$(awk '/var\.operator_role_arn == ""/,/^    \},$/' "$aws_main")
[ -n "$entry" ] || fail "no access entry is created for operator_role_arn"

echo "$entry" | grep -q 'sol:operators' ||
  fail "the operator's access entry does not grant the sol:operators group"

if echo "$entry" | grep -q 'policy_associations'; then
  fail "the operator's access entry carries an EKS access policy; the grant must be the read-only ClusterRole, not a broad managed policy"
fi

grep -q 'let operator_role_binding_doc' "$rbac_doc" ||
  fail "no operator_role_binding_doc: the diagnostic ClusterRole would never be bound"

grep -q '~cluster_role:"sol-operator-diagnostics"' "$rbac_doc" ||
  fail "the operator's RoleBinding does not reference sol-operator-diagnostics"

grep -q '~group:"sol:operators"' "$rbac_doc" ||
  fail "the operator's RoleBinding does not bind the sol:operators group"

grep -q 'Sol_cli_manifest.operator_role_binding_doc ~ns' "$substrate" ||
  fail "Sol_cli_substrate.ensure never applies the operator binding"

deploy_rbac="$root/platform/cloud/modules/platform/platform_deploy_rbac.tf"
[ -f "$deploy_rbac" ] || fail "missing $deploy_rbac"

bind_allowlist=$(awk '/resource_names *= *\[/{f=1} f{print} f && /^[[:space:]]*\][[:space:]]*$/ {exit}' "$deploy_rbac")
[ -n "$bind_allowlist" ] ||
  fail "the deploy bootstrap has no enumerated ClusterRole bind allowlist"

echo "$bind_allowlist" | grep -q 'sol_deploy' ||
  fail "the deploy bootstrap cannot bind sol-deploy, so its own binding is not creatable"

echo "$bind_allowlist" | grep -q 'sol_operator_diagnostics' ||
  fail "the deploy bootstrap cannot bind sol-operator-diagnostics, so the runtime substrate step cannot create the operator's RoleBinding (a live run failed exactly here)"

reconcile="$(
  awk '/^let reconcile_operator_bindings/,/^;;$/' \
    "$root/cli/lib/deploy/sol_cli_substrate.ml"
)"
[ -n "$reconcile" ] || fail "no reconcile_operator_bindings: the grant is still command-scoped"

if echo "$reconcile" | grep -Eq 'ensure|secret_docs|apply_doc'; then
  fail "the operator binding reconciliation is not RBAC-only: it uses the substrate/Secret path"
fi

echo "$reconcile" | grep -Eq 'operator_role_binding_doc|operator_binding_docs' ||
  fail "the reconciliation does not produce the operator's RoleBinding through the RBAC-only document producer"

grep -q 'provider_field target "operator_role_arn"' "$root/cli/lib/cloud/sol_cli_provider_capabilities.ml" ||
  fail "operator_role_arn is declared by the AWS root but never routed to it, so no access entry is created"

canonical() {
  case "$1" in
    ns) echo namespaces ;;
    svc) echo services ;;
    cronjob) echo cronjobs ;;
    deployment) echo deployments ;;
    *) echo "$1" ;;
  esac
}

reads=$(
  grep -hoE '"get"; "[a-z/]+"' \
    "$root/cli/lib/kube/sol_cli_rollout_diagnosis.ml" \
    "$root/cli/bin/cmd_status.ml" \
    "$root/cli/bin/cmd_logs.ml" |
    sed 's/.*"\([a-z/]*\)"$/\1/' |
    sort -u
)

for resource in $reads; do
  api=$(canonical "$resource")
  grep -E 'resources[[:space:]]*=' "$role" | grep -q "\"$api\"" ||
    fail "the read-only diagnostic path reads '$resource' ($api), which the operator's grant does not cover"
done

echo "operator diagnostics: read-only grant, wired end to end, covers the diagnostic path"
