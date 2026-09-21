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

# The substrate step runs as the deploy identity, and Kubernetes only lets a
# RoleBinding grant permissions its creator lacks when the creator holds `bind`
# on that specific ClusterRole. So every ClusterRole the substrate binds must be
# in the bootstrap role's enumerated bind allowlist. A live run failed here:
# sol-operator-diagnostics was bound by the substrate and not bindable, so the
# operator's binding could not be created at all.
deploy_rbac="$root/cli/platform/infra/base/platform_deploy_rbac.tf"
[ -f "$deploy_rbac" ] || fail "missing $deploy_rbac"

# Read to the closing bracket of the *list*, not the first line containing one:
# the entries themselves contain `]` (metadata[0]), which would end an awk range
# on the first entry.
bind_allowlist=$(awk '/resource_names *= *\[/{f=1} f{print} f && /^[[:space:]]*\][[:space:]]*$/ {exit}' "$deploy_rbac")
[ -n "$bind_allowlist" ] ||
  fail "the deploy bootstrap has no enumerated ClusterRole bind allowlist"

echo "$bind_allowlist" | grep -q 'sol_deploy' ||
  fail "the deploy bootstrap cannot bind sol-deploy, so its own binding is not creatable"

echo "$bind_allowlist" | grep -q 'sol_operator_diagnostics' ||
  fail "the deploy bootstrap cannot bind sol-operator-diagnostics, so the runtime substrate step cannot create the operator's RoleBinding (a live run failed exactly here)"

# A declared ARN that never reaches the provider root is exactly how the deploy
# entry was missed once (HARDEN-002 run 3, finding 11). The root declares
# operator_role_arn now, so Sol_cli_config.terraform_vars must route it, or the
# access entry is never created and the identity stays unreachable.
grep -q 'add_opt "operator_role_arn" target.operator_role_arn' "$root/cli/sol/lib/sol_cli_config.ml" ||
  fail "operator_role_arn is declared by the AWS root but never routed to it, so no access entry is created"

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
