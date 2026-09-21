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

# [file] defaults to the AWS root's variables, which is where the first callers
# live; the platform root's own defaults are checked through the same helper so
# the extraction cannot drift between them.
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

# GCP has two independent protections: Terraform's top-level guard and Cloud
# SQL's live API setting. The former alone only stops this Terraform state from
# deleting the instance; it does not establish the Ready-state provider
# invariant or protect against other clients.
gcp="$root/cli/platform/infra/gcp/main.tf"
gcp_vars="$root/cli/platform/infra/gcp/variables.tf"
gcp_sql_block="$(awk '/^resource "google_sql_database_instance" "postgres"/,/^}/' "$gcp")"

if [ -z "$gcp_sql_block" ]; then
  echo "FAIL: google_sql_database_instance.postgres not found in $gcp" >&2
  exit 1
fi

gcp_sql_code="$(printf '%s\n' "$gcp_sql_block" | sed 's/#.*//')"

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

# Sol's GCP output contract is read by name (`gcp_outputs_of_json`), so a renamed
# or dropped output fails at runtime rather than in the type system -- and it fails
# while a lifecycle operation is already under way. The required half is exactly
# what an operation cannot proceed without: the project and region address every
# GCP API call and the cluster credential, the cluster name identifies the target,
# and the registry is what a deploy pushes to.
#
# The undeletability invariant that used to live in this file is now
# `internal/ci/check_destroy_completeness.sh` (ADR 0004), which states the rule
# rather than the two resources that happened to violate it. This one stays here
# because it is about the output contract, not about destruction.
gcp_outputs="$root/cli/platform/infra/gcp/outputs.tf"

if [ ! -f "$gcp_outputs" ]; then
  echo "FAIL: $gcp_outputs is missing" >&2
  exit 1
fi

for gcp_required_output in cluster_name project_id region artifact_registry; do
  if ! grep -q "^output \"$gcp_required_output\" {" "$gcp_outputs"; then
    echo "FAIL: the GCP cloud root no longer publishes \"$gcp_required_output\"," >&2
    echo "      which Sol_cli_cloud_lifecycle.gcp_outputs_of_json requires." >&2
    exit 1
  fi
done

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

# The class must stay AWS-gated. GKE already ships `standard-rwo` as its default,
# so creating this one on GCP as well would leave the cluster with two default
# classes -- which Kubernetes accepts with a warning and then resolves
# arbitrarily, silently putting the platform's durable volumes on a class Sol
# does not own.
case "$sc_code" in
  *'var.create_storage_class && var.cloud_provider == "aws"'*) : ;;
  *)
    echo "FAIL: the platform default StorageClass is no longer created on AWS only;" >&2
    echo "      on GCP GKE's own default class is adopted, and a second default" >&2
    echo "      would be resolved arbitrarily." >&2
    exit 1
    ;;
esac

# That class is asserted in two places that cannot share a literal: Terraform
# creates it, and the `Ready` gate checks the cluster's own answer
# (Sol_cli_cloud_lifecycle.platform_storage). What keeps them from drifting is
# that both name the same class and the same CSI driver -- a rename in one place
# without the other would make `Ready` assert a class the platform never
# created, or create one readiness never looks for.
base_vars="$root/cli/platform/infra/base/variables.tf"
lifecycle_ml="$root/cli/sol/lib/sol_cli_cloud_lifecycle.ml"
created_class="$(variable_default storage_class_name "$base_vars" | tr -d '"')"
created_driver="$(printf '%s\n' "$sc_code" | sed -n 's/.*storage_provisioner *= *"\([^"]*\)".*/\1/p')"

if [ -z "$created_class" ] || [ -z "$created_driver" ]; then
  echo "FAIL: could not read the platform StorageClass's name/provisioner from Terraform" >&2
  exit 1
fi

if ! grep -F "storage_class = \"$created_class\"" "$lifecycle_ml" >/dev/null; then
  echo "FAIL: the Ready gate does not name the StorageClass Terraform creates" >&2
  echo "      ($created_class); the two literals must agree." >&2
  exit 1
fi

if ! grep -F "csi_driver = \"$created_driver\"" "$lifecycle_ml" >/dev/null; then
  echo "FAIL: the Ready gate does not name the CSI driver the platform StorageClass" >&2
  echo "      uses ($created_driver); the two literals must agree." >&2
  exit 1
fi

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

# INFRA-043: the boundary lease is stored in `default`, outside every
# application-namespace RoleBinding.  Its dedicated Role must grant exactly the
# verbs the implementation issues: kubectl get/create/replace/delete maps to
# Kubernetes RBAC get/create/update/delete.  This exact comparison is
# intentional mutation coverage: removing an issued verb or adding an
# unneeded grant fails the offline contract check.
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

lease_impl="$root/cli/sol/lib/sol_cli_boundary_lease.ml"
issued_lease_operations="$(
  grep -o 'Sol_cli_kubectl\.[a-z_]*' "$lease_impl" \
    | sed 's/Sol_cli_kubectl\.//' \
    | sort -u \
    | tr '\n' ' ' \
    | sed 's/ $//'
)"
if [ "$issued_lease_operations" != "create delete get replace" ]; then
  echo "FAIL: boundary-lease kubectl operations changed: $issued_lease_operations" >&2
  echo "      update the least-privilege Role and this explicit contract together" >&2
  exit 1
fi

# DEC-038: `bind` stays scoped to an explicit, enumerated set -- never a wildcard,
# never `escalate` -- and that set now names exactly the ClusterRoles the runtime
# substrate actually binds: sol-deploy (the deploy identity's own) and
# sol-operator-diagnostics (the operator's read-only grant, created per workload
# namespace by Sol_cli_substrate.reconcile_operator_bindings). A third name, a
# wildcard, or an added escalate verb would let the deploy identity bind something
# it has no business binding.
#
# Read to the closing bracket of the *list*: the entries themselves contain `]`
# (metadata[0]), which would end a naive range on the first entry.
bind_allowlist=$(
  awk '/resource_names *= *\[/{f=1} f{print} f && /^[[:space:]]*\][[:space:]]*$/{f=0}' \
    "$root/cli/platform/infra/base/platform_deploy_rbac.tf"
)

# TEMPORARY DIAGNOSTIC (#406): the guard's allowlist extraction came back empty in CI
# while passing locally on identical content. Print what CI actually sees, so the cause
# is an observation rather than a guess. Remove once explained.
{
  echo "DIAGNOSTIC (temporary, #406)"
  echo "  cwd:            $(pwd)"
  echo "  root argument:  $root"
  echo "  rbac file:      $root/cli/platform/infra/base/platform_deploy_rbac.tf"
  echo "  file exists:    $([ -f "$root/cli/platform/infra/base/platform_deploy_rbac.tf" ] && echo yes || echo NO)"
  echo "  file bytes:     $(wc -c < "$root/cli/platform/infra/base/platform_deploy_rbac.tf" 2>/dev/null || echo unavailable)"
  echo "  resource_names lines: $(grep -c 'resource_names' "$root/cli/platform/infra/base/platform_deploy_rbac.tf" 2>/dev/null || echo unavailable)"
  echo "  extracted allowlist:"
  printf '%s\n' "$bind_allowlist" | sed 's/^/    | /'
  echo "  source excerpt:"
  grep -n -B 1 -A 8 'resource_names' "$root/cli/platform/infra/base/platform_deploy_rbac.tf" 2>/dev/null | sed 's/^/    | /'
} >&2

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

if grep -q '"escalate"' "$root/cli/platform/infra/base/platform_deploy_rbac.tf"; then
  echo "FAIL: the deploy bootstrap grants escalate -- it could then grant any" >&2
  echo "      permission, which dissolves the identity boundary." >&2
  exit 1
fi

# INFRA-025: no access entry — and therefore no deploy group membership at
# all — when deploy_role_arn is unset, mirroring provisioner_role_arn's own
# empty-string guard.
aws_main="$root/cli/platform/infra/aws/main.tf"

if ! grep -q 'var.deploy_role_arn == "" ? {} : {' "$aws_main"; then
  echo "FAIL: the AWS root's access_entries no longer guards deploy_role_arn" >&2
  echo "      being unset; an empty ARN must create no access entry." >&2
  exit 1
fi

# HARDEN-002 finding 6: the provisioner must never be able to publish an
# image, and the publisher identity must never be able to provision or
# replace repositories -- both as explicit denies, not merely omitted grants.
bootstrap_tf="$root/cli/platform/infra/bootstrap/main.tf"

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

if ! grep -q 'output "publisher_policy_json"' "$root/cli/platform/infra/bootstrap/outputs.tf"; then
  echo "FAIL: bootstrap root no longer outputs publisher_policy_json" >&2
  exit 1
fi

# HARDEN-002 run 4, finding 13: the deploy identity's ClusterRole grants
# ordinary application verbs the provisioner deliberately does not hold, so the
# steady-state provisioner CANNOT create it (Kubernetes RBAC escalation
# prevention) -- it is created inside the temporary bootstrap-admin window
# instead (see platform_prerequisite_targets in cmd_cloud_tf.ml). That
# sequencing is load-bearing: it only works while the provisioner holds no
# escalate/bind verb. Guard the invariant structurally, so a future change
# cannot "fix" a failing apply by widening the provisioner's steady-state RBAC.
# Comments are stripped first: the file explains this decision in prose.
provisioner_rbac="$root/cli/platform/infra/base/platform_provisioner_rbac.tf"

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

# A Terraform root's backend *type* is part of its own configuration --
# `-backend-config` sets attributes, never the type -- so the platform definition
# `cli/platform/infra/base` cannot carry both the S3 backend AWS needs and the GCS
# backend GCP needs. `cli/platform/infra/base-gcp` is a root that supplies the GCS
# backend and calls the shared definition as a module, which is why `sol cloud`
# selects a platform root per provider.
#
# That makes the wrapper a pass-through whose variable list can drift: a variable
# added to the definition and forgotten here would leave a GCP install unable to
# set it, silently falling back to the definition's default. Only the AWS-shaped
# variables may be missing, and they may only be missing because a provider that
# has no IAM roles or S3 buckets cannot use them -- so the exclusion list itself
# is asserted, not just the count.
wrapper_vars="$root/cli/platform/infra/base-gcp/variables.tf"

if [ ! -f "$wrapper_vars" ]; then
  echo "FAIL: $wrapper_vars is missing; the GCP platform root has no variables" >&2
  exit 1
fi

if ! grep -q 'backend "gcs" {}' "$root/cli/platform/infra/base-gcp/main.tf"; then
  echo "FAIL: the GCP platform root no longer declares the GCS backend, so the type" >&2
  echo "      Sol initializes it with would be the definition's S3 one." >&2
  exit 1
fi

if grep -q 'backend "s3" {}' "$root/cli/platform/infra/gcp/main.tf"; then
  echo "FAIL: the GCP cloud root declares the S3 backend" >&2
  exit 1
fi

declared_vars() {
  grep -h '^variable "' "$@" | sed 's/^variable "\([^"]*\)".*/\1/' | sort
}

# The definition's variables, in every file that declares one.
definition_vars="$(declared_vars "$root"/cli/platform/infra/base/*.tf)"
mirrored_vars="$(declared_vars "$wrapper_vars")"

# The only variables a GCP root may omit: AWS IAM roles and S3 buckets.
aws_only='aws_region cert_manager_irsa_role_arn grafana_irsa_role_arn loki_irsa_role_arn loki_s3_bucket thanos_irsa_role_arn thanos_s3_bucket'

unmirrored="$(comm -23 <(printf '%s\n' "$definition_vars") <(printf '%s\n' "$mirrored_vars"))"
unexpected="$(comm -13 <(printf '%s\n' "$aws_only" | tr ' ' '\n' | sort) <(printf '%s\n' "$unmirrored"))"

if [ -n "$unexpected" ]; then
  echo "FAIL: the GCP platform root does not mirror these declared variables:" >&2
  printf '      %s\n' $unexpected >&2
  echo "      Add them to cli/platform/infra/base-gcp, or add them to the AWS-only" >&2
  echo "      exclusion list here with the reason they cannot apply to GCP." >&2
  exit 1
fi

extra="$(comm -13 <(printf '%s\n' "$definition_vars") <(printf '%s\n' "$mirrored_vars"))"

if [ -n "$extra" ]; then
  echo "FAIL: the GCP platform root declares variables the shared definition does" >&2
  echo "      not, so the module call cannot pass them:" >&2
  printf '      %s\n' $extra >&2
  exit 1
fi

if command -v terraform >/dev/null 2>&1; then
  terraform fmt -check -recursive "$root/cli/platform/infra" >/dev/null
  echo "production infra: precondition present, terraform fmt ok"
else
  echo "production infra: precondition present (terraform not installed, skipped fmt)"
fi
