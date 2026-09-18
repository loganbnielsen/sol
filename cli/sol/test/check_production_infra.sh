#!/usr/bin/env bash
# HARDEN-002 (run 1): the production Postgres path must never send an empty master
# password to AWS. Sol refuses one earlier (test_db_credential), but the provider
# module must also fail on its own, because terraform can be driven directly.
#
# This is deliberately offline: it guards the module-side precondition
# structurally (no terraform, no AWS), and additionally runs `terraform fmt
# -check` when terraform happens to be installed -- `fmt` parses the HCL, so it
# catches syntax breakage without `init`, providers or credentials.
set -euo pipefail

root="$1"
aws="$root/cli/platform/infra/aws/main.tf"

if [ ! -f "$aws" ]; then
  echo "FAIL: $aws is missing" >&2
  exit 1
fi

rds_block="$(awk '/^resource "aws_db_instance" "postgres"/,/^}/' "$aws")"

if [ -z "$rds_block" ]; then
  echo "FAIL: aws_db_instance.postgres not found in $aws" >&2
  exit 1
fi

case "$rds_block" in
  *precondition*) : ;;
  *)
    echo "FAIL: aws_db_instance.postgres has no precondition guarding db_password;" >&2
    echo "      an empty password would again reach CreateDBInstance." >&2
    exit 1
    ;;
esac

case "$rds_block" in
  *db_password*) : ;;
  *)
    echo "FAIL: the RDS precondition no longer mentions db_password" >&2
    exit 1
    ;;
esac

case "$rds_block" in
  *multi_az*) : ;;
  *)
    echo "FAIL: aws_db_instance.postgres lost its multi_az wiring" >&2
    exit 1
    ;;
esac

# HARDEN-002 run 2, finding 9: terraform must be structurally capable of destroying
# the instance -- skip_final_snapshot independent of deletion protection, and an
# identifier present whenever a snapshot will be taken. (Whether *Sol* can destroy a
# protected instance is a separate, open lifecycle question; see cmd_cloud_tf.ml.)
#
# These assert the wires themselves, not merely that the names still appear
# somewhere: a check that only greps for `rds_skip_final_snapshot` passes happily
# while its default flips to true and production destruction goes silent.
vars_tf="$root/cli/platform/infra/aws/variables.tf"

variable_default() {
  awk -v want="variable \"$1\" {" '
    index($0, want) == 1 { inside = 1; next }
    inside && /^}/ { exit }
    inside && $1 == "default" { print $3; exit }
  ' "$vars_tf"
}

if [ "$(variable_default rds_deletion_protection)" != "true" ]; then
  echo "FAIL: rds_deletion_protection no longer defaults to true;" >&2
  echo "      a production database would be destroyable by an ordinary apply." >&2
  exit 1
fi

if [ "$(variable_default rds_skip_final_snapshot)" != "false" ]; then
  echo "FAIL: rds_skip_final_snapshot no longer defaults to false;" >&2
  echo "      destroying production Postgres would take no final snapshot." >&2
  exit 1
fi

# Comments stripped: the block explains finding 9 in prose directly above these
# assignments, so a match against the raw text would be satisfied by the comment
# that survives the very deletion this is guarding against.
rds_code="$(printf '%s\n' "$rds_block" | sed 's/#.*//')"

case "$rds_code" in
  *"skip_final_snapshot = var.rds_skip_final_snapshot"*) : ;;
  *)
    echo "FAIL: aws_db_instance.postgres no longer takes skip_final_snapshot from its own" >&2
    echo "      variable; finding 9 was that this was derived from deletion protection." >&2
    exit 1
    ;;
esac

case "$rds_code" in
  *"final_snapshot_identifier = "*) : ;;
  *)
    echo "FAIL: aws_db_instance.postgres sets no final_snapshot_identifier, so terraform" >&2
    echo "      refuses to destroy it at all whenever a final snapshot is required." >&2
    exit 1
    ;;
esac

# Nothing is asserted about cmd_cloud_tf.ml here. `sol cloud destroy` used to append
# `-var rds_deletion_protection=false` and a generated snapshot name, and those two
# greps passed while the behaviour was inert: a `-var` cannot reach a destroy plan,
# which is handed prior state. Preparing a protected instance for destruction is a
# separate applied transition; when it exists it will be asserted by what it does,
# not by a string in the file.

# HARDEN-002 run 2, finding 7: the default StorageClass provisions the volumes that
# hold the platform's durable data, so it carries the substrate's at-rest posture.
# Encryption-by-default is an account setting Sol does not own; stating it in the
# class is what makes it true anywhere. Comment-stripped for the reason above.
sc_code="$(awk '/^resource "kubernetes_storage_class_v1" "platform_default"/,/^}/' \
  "$root/cli/platform/infra/base/main.tf" | sed 's/#.*//')"

if [ -z "$sc_code" ]; then
  echo "FAIL: kubernetes_storage_class_v1.platform_default not found" >&2
  exit 1
fi

case "$sc_code" in
  *'encrypted = "true"'*) : ;;
  *)
    echo "FAIL: the default StorageClass no longer sets encrypted = \"true\";" >&2
    echo "      Redpanda's log, in-cluster Postgres, Loki and Prometheus would be" >&2
    echo "      unencrypted at rest on any account without EBS encryption-by-default." >&2
    exit 1
    ;;
esac

# INFRA-025: the deploy identity's own ClusterRole (Deployments/Secrets/etc.)
# must never be bound cluster-wide -- only per application namespace, applied
# at runtime by Sol_cli_substrate.ensure. A kubernetes_cluster_role_binding
# referencing it here would leak deploy into every platform namespace's own
# Secrets/Deployments, silently reintroducing exactly what this ticket exists
# to prevent.
deploy_rbac="$root/cli/platform/infra/base/platform_deploy_rbac.tf"

if [ ! -f "$deploy_rbac" ]; then
  echo "FAIL: $deploy_rbac is missing" >&2
  exit 1
fi

if ! grep -q 'resource "kubernetes_cluster_role" "sol_deploy" {' "$deploy_rbac"; then
  echo "FAIL: kubernetes_cluster_role.sol_deploy not found" >&2
  exit 1
fi

if grep -q 'kubernetes_cluster_role_binding' "$deploy_rbac" \
  && awk '/^resource "kubernetes_cluster_role_binding"/,/^}/' "$deploy_rbac" \
    | grep -q 'kubernetes_cluster_role\.sol_deploy\.metadata'; then
  echo "FAIL: kubernetes_cluster_role.sol_deploy is bound by a ClusterRoleBinding --" >&2
  echo "      it must only ever be bound per namespace, at runtime" >&2
  exit 1
fi

# The bootstrap role exists to let deploy create a namespace/RoleBinding that
# does not exist yet; it must stay create-only on both, and its only
# clusterroles grant must be "bind" scoped to sol-deploy specifically (never
# "get"/"list"/"*", which would let it discover or reference other roles, and
# never leaving resource_names unset, which would let it bind ANY ClusterRole
# -- including a future one this repo adds with broader permissions).
bootstrap_role="$(awk '/^resource "kubernetes_cluster_role" "sol_deploy_bootstrap"/,/^}/' "$deploy_rbac")"

if [ -z "$bootstrap_role" ]; then
  echo "FAIL: kubernetes_cluster_role.sol_deploy_bootstrap not found" >&2
  exit 1
fi

case "$bootstrap_role" in
  *'verbs      = ["get", "list", "watch", "create"]'*) : ;;
  *)
    echo "FAIL: sol-deploy-bootstrap's namespaces/rolebindings rules are no longer" >&2
    echo "      create-only; this identity must never patch/update/delete either kind." >&2
    exit 1
    ;;
esac

case "$bootstrap_role" in
  *'resource_names = [kubernetes_cluster_role.sol_deploy.metadata[0].name]'*'verbs          = ["bind"]'*) : ;;
  *)
    echo "FAIL: sol-deploy-bootstrap's clusterroles rule no longer scopes \"bind\" to" >&2
    echo "      sol-deploy by resource_names -- it could then bind any ClusterRole." >&2
    exit 1
    ;;
esac

# INFRA-025: no access entry — and therefore no deploy group membership at
# all — when deploy_role_arn is unset, mirroring provisioner_role_arn's own
# empty-string guard.
aws_main="$root/cli/platform/infra/aws/main.tf"

if ! grep -q 'var.deploy_role_arn == "" ? {} : {' "$aws_main"; then
  echo "FAIL: the AWS root's access_entries no longer guards deploy_role_arn" >&2
  echo "      being unset; an empty ARN must create no access entry." >&2
  exit 1
fi

if command -v terraform >/dev/null 2>&1; then
  terraform fmt -check -recursive "$root/cli/platform/infra" >/dev/null
  echo "production infra: precondition present, terraform fmt ok"
else
  echo "production infra: precondition present (terraform not installed, skipped fmt)"
fi
