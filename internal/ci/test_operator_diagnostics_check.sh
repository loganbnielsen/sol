#!/usr/bin/env bash
set -euo pipefail

# DEC-038 / INFRA-057: proves check_operator_diagnostics.sh can fail.
#
# A guard that cannot fail is decoration. Each case below breaks exactly one
# property the operator identity is supposed to have, in a copy of the real files,
# and requires the guard to reject it -- including the case that matters most for
# "derived from actual evidence": a diagnostic command starting to read something
# the operator's grant does not cover.

repo="${1:-$(git rev-parse --show-toplevel)}"
guard="$repo/internal/ci/check_operator_diagnostics.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

files=(
  cli/platform/infra/base/platform_operator_rbac.tf
  cli/platform/infra/aws/main.tf
  cli/platform/infra/aws/variables.tf
  cli/sol/lib/sol_cli_manifest_yaml.ml
  cli/sol/lib/sol_cli_substrate.ml
  cli/sol/lib/sol_cli_rollout_diagnosis.ml
  cli/sol/bin/cmd_status.ml
  cli/sol/bin/cmd_logs.ml
  cli/sol/lib/sol_cli_config.ml
  cli/platform/infra/base/platform_deploy_rbac.tf
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

# ── the pristine copy passes ────────────────────────────────────────────────
seed
expect_pass

# ── a mutating verb ─────────────────────────────────────────────────────────
seed
sed -i 's/    verbs      = \["get", "list"\]/    verbs      = ["get", "list", "delete"]/' \
  "$work/root/cli/platform/infra/base/platform_operator_rbac.tf"
expect_fail "a mutating verb"

# ── secrets ─────────────────────────────────────────────────────────────────
seed
sed -i 's/resources  = \["pods", "pods\/log", "services", "events"\]/resources  = ["pods", "pods\/log", "services", "events", "secrets"]/' \
  "$work/root/cli/platform/infra/base/platform_operator_rbac.tf"
expect_fail "secrets in the grant"

# ── interactive debugging ───────────────────────────────────────────────────
seed
sed -i 's/resources  = \["pods", "pods\/log", "services", "events"\]/resources  = ["pods", "pods\/log", "services", "events", "pods\/portforward"]/' \
  "$work/root/cli/platform/infra/base/platform_operator_rbac.tf"
expect_fail "pods/portforward"

# ── the identity loses its access entry ─────────────────────────────────────
seed
python3 - "$work/root/cli/platform/infra/aws/main.tf" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
start = s.index("    var.operator_role_arn ==")
end = s.index("    },\n", s.index("kubernetes_groups = [\"sol:operators\"]")) + len("    },\n")
open(p, "w").write(s[:start] + s[end:])
PY
expect_fail "a missing access entry"

# ── the entry carries a broad managed policy instead of the role ────────────
seed
python3 - "$work/root/cli/platform/infra/aws/main.tf" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'kubernetes_groups = ["sol:operators"]'
new = old + '\n        policy_associations = { view = { policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy" } }'
assert old in s
open(p, "w").write(s.replace(old, new, 1))
PY
expect_fail "a managed access policy on the operator entry"

# ── the binding is never applied ────────────────────────────────────────────
seed
sed -i 's/operator_role_binding_doc ~ns/operator_role_binding_doc_DISABLED ~ns/g' \
  "$work/root/cli/sol/lib/sol_cli_substrate.ml"
expect_fail "a ClusterRole that is never bound"

# ── the diagnostic path reads something the grant does not cover ────────────
# The property the whole exercise is about: the grant must follow the evidence
# Sol's read-only commands actually consume.
seed
python3 - "$work/root/cli/sol/bin/cmd_status.ml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '[ "get"; "ns"; ns ]'
new = '[ "get"; "configmaps"; "-n"; ns ]'
assert old in s
open(p, "w").write(s.replace(old, new, 1))
PY
expect_fail "a new read the operator cannot perform"

# ── the declared ARN never reaches the provider root ────────────────────────
seed
sed -i 's/        |> add_opt "operator_role_arn" target.operator_role_arn/        |> ignore/' \
  "$work/root/cli/sol/lib/sol_cli_config.ml"
expect_fail "an ARN that never reaches the provider root"

# ── the substrate identity cannot bind what the substrate creates ───────────
# The condition a live run failed on: the operator's RoleBinding is created by the
# runtime substrate (as the deploy identity), so sol-operator-diagnostics must be
# in that identity's enumerated bind allowlist.
seed
python3 - "$work/root/cli/platform/infra/base/platform_deploy_rbac.tf" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "      kubernetes_cluster_role.sol_operator_diagnostics.metadata[0].name,\n"
assert old in s
open(p, "w").write(s.replace(old, "", 1))
PY
expect_fail "an operator RoleBinding the substrate identity cannot bind"

# ── the reconciliation stops being RBAC only ────────────────────────────────
# The failure mode this guards: "simplifying" it to reuse the substrate path, which
# also writes runtime Secrets.
seed
python3 - "$work/root/cli/sol/lib/sol_cli_substrate.ml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "  create_all (operator_binding_docs ~workspace (Sol_cli_manifest.discover_services ()))"
assert old in s
new = "  let _ = secret_docs [] in\n" + old
open(p, "w").write(s.replace(old, new, 1))
PY
expect_fail "a reconciliation that writes Secrets"

echo "operator diagnostics check: every guard rejection reproduced"
