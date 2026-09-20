#!/usr/bin/env bash
set -euo pipefail

# DEC-038 / INFRA-057: the operator identity owns production observation and
# diagnosis, and its Kubernetes grant must be *derived from the evidence Sol's
# read-only commands actually consume* -- not from a convenient posture.
#
# So this does two things the RBAC text alone cannot. It pins the role to
# read-only and to the three deliberate omissions, and it **cross-checks the
# code**: every resource the diagnostic path reads must appear in the grant. A new
# read in `sol status` therefore fails here until the operator can perform it,
# which is the point of having the identity at all.
#
# The grant is verified from the Terraform plus the two runtime facts (the
# RoleBinding document, and that the substrate actually applies it), because a
# ClusterRole with no binding grants nothing -- which is exactly the defect this
# ticket fixes, one layer up.

root="${1:-$(git rev-parse --show-toplevel)}"

role="$root/cli/platform/infra/base/platform_operator_rbac.tf"
aws_main="$root/cli/platform/infra/aws/main.tf"
aws_vars="$root/cli/platform/infra/aws/variables.tf"
rbac_doc="$root/cli/sol/lib/sol_cli_manifest_yaml.ml"
substrate="$root/cli/sol/lib/sol_cli_substrate.ml"

fail() {
  echo "check_operator_diagnostics: $1" >&2
  exit 1
}

for f in "$role" "$aws_main" "$aws_vars" "$rbac_doc" "$substrate"; do
  [ -f "$f" ] || fail "missing $f"
done

# ── the grant is read-only ───────────────────────────────────────────────────
if grep -E 'verbs[[:space:]]*=' "$role" | grep -Eq '"(create|update|patch|delete|deletecollection)"'; then
  fail "the operator's role grants a mutating verb; it owns observation only"
fi

if grep -Eq 'verbs[[:space:]]*=[[:space:]]*\["\*"\]' "$role"; then
  fail "the operator's role uses a wildcard verb"
fi

# ── the three deliberate omissions (DEC-038 §4) ──────────────────────────────
if grep -E 'resources[[:space:]]*=' "$role" | grep -Eq '"secrets"'; then
  fail "the operator's role grants secrets: inspection is not diagnosis"
fi

if grep -E 'resources[[:space:]]*=' "$role" | grep -Eq 'pods/(exec|portforward|attach)'; then
  fail "the operator's role grants interactive debugging; DEC-038 excludes it from the diagnostic surface"
fi

# ── the identity is wired end to end ─────────────────────────────────────────
grep -q 'variable "operator_role_arn"' "$aws_vars" ||
  fail "operator_role_arn is not a variable of the AWS root"

entry=$(awk '/var\.operator_role_arn == ""/,/^    \},$/' "$aws_main")
[ -n "$entry" ] || fail "no access entry is created for operator_role_arn"

echo "$entry" | grep -q 'sol:operators' ||
  fail "the operator's access entry does not grant the sol:operators group"

if echo "$entry" | grep -q 'policy_associations'; then
  fail "the operator's access entry carries an EKS access policy; the grant must be the read-only ClusterRole, not a broad managed policy"
fi

# ── the runtime binding, without which the ClusterRole is inert ──────────────
grep -q 'let operator_role_binding_doc' "$rbac_doc" ||
  fail "no operator_role_binding_doc: the diagnostic ClusterRole would never be bound"

grep -q 'name: sol-operator-diagnostics' "$rbac_doc" ||
  fail "the operator's RoleBinding does not reference sol-operator-diagnostics"

grep -q 'name: sol:operators' "$rbac_doc" ||
  fail "the operator's RoleBinding does not bind the sol:operators group"

grep -q 'Sol_cli_manifest.operator_role_binding_doc ~ns' "$substrate" ||
  fail "Sol_cli_substrate.ensure never applies the operator binding"

# ── the cross-check: what the diagnostic path reads, the operator must see ───
# kubectl's short spellings, mapped to the API resource the grant names.
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
    "$root/cli/sol/lib/sol_cli_rollout_diagnosis.ml" \
    "$root/cli/sol/bin/cmd_status.ml" \
    "$root/cli/sol/bin/cmd_logs.ml" |
    sed 's/.*"\([a-z/]*\)"$/\1/' |
    sort -u
)

for resource in $reads; do
  api=$(canonical "$resource")
  grep -E 'resources[[:space:]]*=' "$role" | grep -q "\"$api\"" ||
    fail "the read-only diagnostic path reads '$resource' ($api), which the operator's grant does not cover"
done

echo "operator diagnostics: read-only grant, wired end to end, covers the diagnostic path"
