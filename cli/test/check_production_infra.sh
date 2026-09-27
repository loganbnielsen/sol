#!/usr/bin/env bash
set -euo pipefail

root="$1"
aws="$root/platform/cloud/aws/cluster/main.tf"

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

vars_tf="$root/platform/cloud/aws/cluster/variables.tf"

variable_default() {
  local name="$1" file="${2:-$vars_tf}"
  awk -v want="variable \"$name\" {" '
    index($0, want) == 1 { inside = 1; next }
    inside && /^}/ { exit }
    inside && $1 == "default" { print $3; exit }
  ' "$file"
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

gcp="$root/platform/cloud/gcp/cluster/main.tf"
gcp_vars="$root/platform/cloud/gcp/cluster/variables.tf"
gcp_sql_block="$(awk '/^resource "google_sql_database_instance" "postgres"/,/^}/' "$gcp")"

if [ -z "$gcp_sql_block" ]; then
  echo "FAIL: google_sql_database_instance.postgres not found in $gcp" >&2
  exit 1
fi

gcp_sql_code="$(printf '%s\n' "$gcp_sql_block" | sed 's/#.*//' | tr -s ' ')"

case "$gcp_sql_code" in
  *"deletion_protection = var.sql_deletion_protection"*) : ;;
  *)
    echo "FAIL: Cloud SQL no longer wires Terraform's deletion-protection guard." >&2
    exit 1
    ;;
esac

case "$gcp_sql_code" in
  *"deletion_protection_enabled = var.sql_deletion_protection"*) : ;;
  *)
    echo "FAIL: Cloud SQL no longer wires the live API deletion-protection setting." >&2
    exit 1
    ;;
esac

gcp_deletion_default="$(awk '
  index($0, "variable \"sql_deletion_protection\" {") == 1 { inside = 1; next }
  inside && /^}/ { exit }
  inside && $1 == "default" { print $3; exit }
' "$gcp_vars")"

if [ "$gcp_deletion_default" != "true" ]; then
  echo "FAIL: sql_deletion_protection no longer defaults to true" >&2
  exit 1
fi

gcp_outputs="$root/platform/cloud/gcp/cluster/outputs.tf"

if [ ! -f "$gcp_outputs" ]; then
  echo "FAIL: $gcp_outputs is missing" >&2
  exit 1
fi

for gcp_required_output in cluster_name project_id region artifact_registry; do
  if ! grep -q "^output \"$gcp_required_output\" {" "$gcp_outputs"; then
    echo "FAIL: the GCP cloud root no longer publishes \"$gcp_required_output\"," >&2
    echo "      which Sol_cli_gcp_cluster.gcp_outputs_of_json requires." >&2
    exit 1
  fi
done

rds_code="$(printf '%s\n' "$rds_block" | sed 's/#.*//' | tr -s ' ')"

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

sc_code="$(awk '/^resource "kubernetes_storage_class_v1" "platform_default"/,/^}/' \
  "$root/platform/cloud/modules/platform/main.tf" | sed 's/#.*//')"

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

case "$sc_code" in
  *'var.create_storage_class && var.cloud_provider == "aws"'*) : ;;
  *)
    echo "FAIL: the platform default StorageClass is no longer created on AWS only;" >&2
    echo "      on GCP GKE's own default class is adopted, and a second default" >&2
    echo "      would be resolved arbitrarily." >&2
    exit 1
    ;;
esac

base_vars="$root/platform/cloud/modules/platform/variables.tf"
capabilities_ml="$root/cli/lib/cloud/sol_cli_provider_capabilities.ml"
created_class="$(variable_default storage_class_name "$base_vars" | tr -d '"')"
created_driver="$(printf '%s\n' "$sc_code" | sed -n 's/.*storage_provisioner *= *"\([^"]*\)".*/\1/p')"

if [ -z "$created_class" ] || [ -z "$created_driver" ]; then
  echo "FAIL: could not read the platform StorageClass's name/provisioner from Terraform" >&2
  exit 1
fi

if ! grep -F "storage_class = \"$created_class\"" "$capabilities_ml" >/dev/null; then
  echo "FAIL: the Ready gate does not name the StorageClass Terraform creates" >&2
  echo "      ($created_class); the two literals must agree." >&2
  exit 1
fi

if ! grep -F "csi_driver = \"$created_driver\"" "$capabilities_ml" >/dev/null; then
  echo "FAIL: the Ready gate does not name the CSI driver the platform StorageClass" >&2
  echo "      uses ($created_driver); the two literals must agree." >&2
  exit 1
fi

deploy_rbac="$root/platform/cloud/modules/platform/platform_deploy_rbac.tf"

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

lease_role="$(awk '/^resource "kubernetes_role" "sol_boundary_lease"/,/^}/' "$deploy_rbac")"

if [ -z "$lease_role" ]; then
  echo "FAIL: kubernetes_role.sol_boundary_lease not found" >&2
  exit 1
fi

case "$lease_role" in
  *'namespace = "default"'*'resources  = ["configmaps"]'*'verbs      = ["create"]'*'verbs      = ["get", "update", "delete"]'*) : ;;
  *)
    echo "FAIL: the boundary-lease Role must grant exactly get/create/update/delete" >&2
    echo "      on ConfigMaps in the default namespace" >&2
    exit 1
    ;;
esac

lease_binding="$(awk '/^resource "kubernetes_role_binding" "sol_boundary_lease"/,/^}/' "$deploy_rbac")"
case "$lease_binding" in
  *'namespace = "default"'*'name      = kubernetes_role.sol_boundary_lease.metadata[0].name'*'name      = "sol:deployers"'*) : ;;
  *)
    echo "FAIL: the boundary-lease Role is not bound to sol:deployers in default" >&2
    exit 1
    ;;
esac

lease_impl="$root/cli/lib/deploy/sol_cli_boundary_lease.ml"
issued_lease_operations="$(
  grep -o 'Sol_cli_kubectl\.[a-z_]*' "$lease_impl" \
    | sed 's/Sol_cli_kubectl\.//' \
    | sed 's/^get_if_present$/get/' \
    | grep -vx 'classify' \
    | sort -u \
    | tr '\n' ' ' \
    | sed 's/ $//'
)"
if [ "$issued_lease_operations" != "create delete get replace" ]; then
  echo "FAIL: boundary-lease kubectl operations changed: $issued_lease_operations" >&2
  echo "      update the least-privilege Role and this explicit contract together" >&2
  exit 1
fi

bind_allowlist=$(
  awk '/resource_names *= *\[/{f=1} f{print} f && /^[[:space:]]*\][[:space:]]*$/{f=0}' \
    "$root/platform/cloud/modules/platform/platform_deploy_rbac.tf"
)

if ! printf '%s' "$bind_allowlist" | grep -q 'kubernetes_cluster_role.sol_deploy.metadata'; then
  echo "FAIL: sol-deploy is no longer in the deploy bootstrap's bind allowlist" >&2
  exit 1
fi

if ! printf '%s' "$bind_allowlist" | grep -q 'kubernetes_cluster_role.sol_operator_diagnostics.metadata'; then
  echo "FAIL: the operator's read-only ClusterRole is not in the deploy bootstrap's" >&2
  echo "      bind allowlist, so the runtime substrate cannot create the operator's" >&2
  echo "      RoleBinding (found live, before this was added)." >&2
  exit 1
fi

if printf '%s' "$bind_allowlist" | grep -q '"\*"'; then
  echo "FAIL: the deploy bootstrap's bind allowlist uses a wildcard -- it could then" >&2
  echo "      bind any ClusterRole." >&2
  exit 1
fi

if grep -q '"escalate"' "$root/platform/cloud/modules/platform/platform_deploy_rbac.tf"; then
  echo "FAIL: the deploy bootstrap grants escalate -- it could then grant any" >&2
  echo "      permission, which dissolves the identity boundary." >&2
  exit 1
fi

aws_main="$root/platform/cloud/aws/cluster/main.tf"

if ! grep -q 'var.deploy_role_arn == "" ? {} : {' "$aws_main"; then
  echo "FAIL: the AWS root's access_entries no longer guards deploy_role_arn" >&2
  echo "      being unset; an empty ARN must create no access entry." >&2
  exit 1
fi

bootstrap_tf="$root/platform/cloud/aws/bootstrap/main.tf"

provisioner_policy="$(awk '/^data "aws_iam_policy_document" "provisioner"/,/^}/' "$bootstrap_tf")"

if [ -z "$provisioner_policy" ]; then
  echo "FAIL: data.aws_iam_policy_document.provisioner not found" >&2
  exit 1
fi

case "$provisioner_policy" in
  *'sid    = "NoImagePublish"'*'"ecr:PutImage"'*) : ;;
  *)
    echo "FAIL: the provisioner policy no longer explicitly denies ecr:PutImage" >&2
    echo "      (and friends) -- ADR 0002's 'provisioner must not publish' boundary" >&2
    echo "      would then rest on omission alone." >&2
    exit 1
    ;;
esac

publisher_policy="$(awk '/^data "aws_iam_policy_document" "publisher"/,/^}/' "$bootstrap_tf")"

if [ -z "$publisher_policy" ]; then
  echo "FAIL: data.aws_iam_policy_document.publisher not found" >&2
  exit 1
fi

case "$publisher_policy" in
  *'"ecr:PutImage"'*) : ;;
  *)
    echo "FAIL: the publisher policy no longer grants ecr:PutImage" >&2
    exit 1
    ;;
esac

case "$publisher_policy" in
  *'sid    = "NoProvisionOrDeploy"'*'"eks:*"'*'"iam:*"'*) : ;;
  *)
    echo "FAIL: the publisher policy no longer explicitly denies provisioning/IAM" >&2
    echo "      mutation -- publishing an image must not also grant those." >&2
    exit 1
    ;;
esac

if ! grep -q 'output "publisher_policy_json"' "$root/platform/cloud/aws/bootstrap/outputs.tf"; then
  echo "FAIL: bootstrap root no longer outputs publisher_policy_json" >&2
  exit 1
fi

provisioner_rbac="$root/platform/cloud/modules/platform/platform_provisioner_rbac.tf"

if [ ! -f "$provisioner_rbac" ]; then
  echo "FAIL: $provisioner_rbac is missing" >&2
  exit 1
fi

if printf '%s\n' "$(sed 's/#.*//' "$provisioner_rbac")" | grep -Eq '"(escalate|bind)"'; then
  echo "FAIL: the steady-state platform provisioner RBAC grants escalate/bind;" >&2
  echo "      the deploy ClusterRole must be created inside the bootstrap-admin" >&2
  echo "      window, not by widening the provisioner's standing authority." >&2
  exit 1
fi

module_dir="$root/platform/cloud/modules/platform"

if grep -q '^[[:space:]]*backend "' "$module_dir"/*.tf; then
  echo "FAIL: the shared platform module declares a backend; a module's backend is" >&2
  echo "      ignored, so it would only mislead. Backends belong to the provider roots." >&2
  exit 1
fi

if grep -q 'backend "s3" {}' "$root/platform/cloud/gcp/cluster/main.tf"; then
  echo "FAIL: the GCP cloud root declares the S3 backend" >&2
  exit 1
fi

declared_vars() {
  grep -h '^variable "' "$@" | sed 's/^variable "\([^"]*\)".*/\1/' | sort
}

definition_vars="$(declared_vars "$module_dir"/*.tf)"

check_platform_root() {
  local provider="$1" backend="$2" may_omit="$3"
  local dir="$root/platform/cloud/$provider/platform"
  local vars_file="$dir/variables.tf"

  if [ ! -f "$vars_file" ]; then
    echo "FAIL: $vars_file is missing; the $provider platform root has no variables" >&2
    exit 1
  fi
  if ! grep -q "backend \"$backend\" {}" "$dir/main.tf"; then
    echo "FAIL: the $provider platform root no longer declares the $backend backend," >&2
    echo "      so Sol would initialize it with the wrong backend type." >&2
    exit 1
  fi

  local mirrored unmirrored unexpected extra unpassed
  mirrored="$(declared_vars "$vars_file")"
  unmirrored="$(comm -23 <(printf '%s\n' "$definition_vars") <(printf '%s\n' "$mirrored"))"
  unexpected="$(comm -13 <(printf '%s\n' "$may_omit" | tr ' ' '\n' | sed '/^$/d' | sort) <(printf '%s\n' "$unmirrored" | sed '/^$/d'))"
  if [ -n "$unexpected" ]; then
    echo "FAIL: the $provider platform root does not mirror these declared variables:" >&2
    printf '      %s\n' $unexpected >&2
    echo "      Add them to platform/cloud/$provider/platform, or to its exclusion list" >&2
    echo "      here with the reason they cannot apply to $provider." >&2
    exit 1
  fi

  extra="$(comm -13 <(printf '%s\n' "$definition_vars") <(printf '%s\n' "$mirrored"))"
  if [ -n "$extra" ]; then
    echo "FAIL: the $provider platform root declares variables the shared definition" >&2
    echo "      does not, so the module call cannot pass them:" >&2
    printf '      %s\n' $extra >&2
    exit 1
  fi

  unpassed=""
  for v in $mirrored; do
    grep -qE "^[[:space:]]*$v[[:space:]]*=[[:space:]]*var\.$v\b" "$dir/main.tf" || unpassed="$unpassed $v"
  done
  if [ -n "$unpassed" ]; then
    echo "FAIL: the $provider platform root declares but does not pass to the module:" >&2
    printf '      %s\n' $unpassed >&2
    exit 1
  fi
}

check_platform_root aws s3 ""
check_platform_root gcp gcs 'aws_region cert_manager_irsa_role_arn grafana_irsa_role_arn loki_irsa_role_arn loki_s3_bucket thanos_irsa_role_arn thanos_s3_bucket'

if command -v terraform >/dev/null 2>&1; then
  terraform fmt -check -recursive "$root/platform/cloud" >/dev/null
  echo "production infra: precondition present, terraform fmt ok"
else
  echo "production infra: precondition present (terraform not installed, skipped fmt)"
fi
