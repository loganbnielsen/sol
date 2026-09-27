#!/usr/bin/env bash
set -euo pipefail

repo="${1:-$(git rev-parse --show-toplevel)}"
guard="$repo/internal/ci/check_operator_diagnostics.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

files=(
  platform/cloud/modules/platform/platform_operator_rbac.tf
  platform/cloud/aws/cluster/main.tf
  platform/cloud/aws/cluster/variables.tf
  cli/lib/workspace/sol_cli_manifest_yaml.ml
  cli/lib/deploy/sol_cli_substrate.ml
  cli/lib/kube/sol_cli_rollout_diagnosis.ml
  cli/bin/cmd_status.ml
  cli/bin/cmd_logs.ml
  cli/lib/cloud/sol_cli_provider_capabilities.ml
  platform/cloud/modules/platform/platform_deploy_rbac.tf
)

seed() {
  rm -rf "$work/root"
  for f in "${files[@]}"; do
    mkdir -p "$work/root/$(dirname "$f")"
    cp "$repo/$f" "$work/root/$f"
  done
}

expect_pass() {
  if ! bash "$guard" "$work/root" >"$work/out" 2>&1; then
    echo "test_operator_diagnostics: expected the guard to pass, but it failed:" >&2
    cat "$work/out" >&2
    exit 1
  fi
}

expect_fail() {
  local what="$1"
  if bash "$guard" "$work/root" >"$work/out" 2>&1; then
    echo "test_operator_diagnostics: the guard accepted $what" >&2
    exit 1
  fi
}

seed
expect_pass

seed
sed -i 's/    verbs      = \["get", "list"\]/    verbs      = ["get", "list", "delete"]/' \
  "$work/root/platform/cloud/modules/platform/platform_operator_rbac.tf"
expect_fail "a mutating verb"

seed
sed -i 's/resources  = \["pods", "pods\/log", "services", "events"\]/resources  = ["pods", "pods\/log", "services", "events", "secrets"]/' \
  "$work/root/platform/cloud/modules/platform/platform_operator_rbac.tf"
expect_fail "secrets in the grant"

seed
sed -i 's/resources  = \["pods", "pods\/log", "services", "events"\]/resources  = ["pods", "pods\/log", "services", "events", "pods\/portforward"]/' \
  "$work/root/platform/cloud/modules/platform/platform_operator_rbac.tf"
expect_fail "pods/portforward"

seed
python3 - "$work/root/platform/cloud/aws/cluster/main.tf" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
start = s.index("    var.operator_role_arn ==")
end = s.index("    },\n", s.index("kubernetes_groups = [\"sol:operators\"]")) + len("    },\n")
open(p, "w").write(s[:start] + s[end:])
PY
expect_fail "a missing access entry"

seed
python3 - "$work/root/platform/cloud/aws/cluster/main.tf" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'kubernetes_groups = ["sol:operators"]'
new = old + '\n        policy_associations = { view = { policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy" } }'
assert old in s
open(p, "w").write(s.replace(old, new, 1))
PY
expect_fail "a managed access policy on the operator entry"

seed
sed -i 's/operator_role_binding_doc ~ns/operator_role_binding_doc_DISABLED ~ns/g' \
  "$work/root/cli/lib/deploy/sol_cli_substrate.ml"
expect_fail "a ClusterRole that is never bound"

seed
sed -i 's/~cluster_role:"sol-operator-diagnostics"/~cluster_role:"cluster-admin"/' \
  "$work/root/cli/lib/workspace/sol_cli_manifest_yaml.ml"
expect_fail "the operator binding pointed at another ClusterRole"

seed
sed -i 's/~group:"sol:operators"/~group:"system:authenticated"/' \
  "$work/root/cli/lib/workspace/sol_cli_manifest_yaml.ml"
expect_fail "the operator binding granted to another group"

seed
python3 - "$work/root/cli/bin/cmd_status.ml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '[ "get"; "ns"; ns ]'
new = '[ "get"; "configmaps"; "-n"; ns ]'
assert old in s
open(p, "w").write(s.replace(old, new, 1))
PY
expect_fail "a new read the operator cannot perform"

seed
sed -i 's/(Sol_cli_config.provider_field target "operator_role_arn")/None/' \
  "$work/root/cli/lib/cloud/sol_cli_provider_capabilities.ml"
expect_fail "an ARN that never reaches the provider root"

seed
python3 - "$work/root/platform/cloud/modules/platform/platform_deploy_rbac.tf" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "      kubernetes_cluster_role.sol_operator_diagnostics.metadata[0].name,\n"
assert old in s
open(p, "w").write(s.replace(old, "", 1))
PY
expect_fail "an operator RoleBinding the substrate identity cannot bind"

seed
python3 - "$work/root/cli/lib/deploy/sol_cli_substrate.ml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "  let failures ="
assert old in s
new = "  let _ = secret_docs [] in\n" + old
open(p, "w").write(s.replace(old, new, 1))
PY
expect_fail "a reconciliation that writes Secrets"

echo "operator diagnostics check: every guard rejection reproduced"
