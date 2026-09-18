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

if command -v terraform >/dev/null 2>&1; then
  terraform fmt -check -recursive "$root/cli/platform/infra" >/dev/null
  echo "production infra: precondition present, terraform fmt ok"
else
  echo "production infra: precondition present (terraform not installed, skipped fmt)"
fi
