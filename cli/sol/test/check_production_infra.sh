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

if command -v terraform >/dev/null 2>&1; then
  terraform fmt -check -recursive "$root/cli/platform/infra" >/dev/null
  echo "production infra: precondition present, terraform fmt ok"
else
  echo "production infra: precondition present (terraform not installed, skipped fmt)"
fi
