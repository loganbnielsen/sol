#!/usr/bin/env bash
# Mutation test for check_destroy_completeness.sh (ADR 0004).
#
# A structural guard that cannot fail is decoration. This feeds it a target root
# holding each defect the audit actually found, and asserts it refuses -- and
# then feeds it the repaired shape and asserts it accepts. The AWS and GCP
# providers are exercised separately because the guard claims to hold the
# invariant across both, not the AWS spelling of it.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
guard="$root/internal/ci/check_destroy_completeness.sh"

if [ ! -x "$guard" ]; then
  echo "test_destroy_completeness_check: guard is not executable: $guard" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$(cd "$(dirname "$0")/../.." && pwd)"

mk() {
  # mk <dir> <file> <contents>; each fake repo carries the real provider list,
  # which is where the guard learns its target roots (HARDEN-005).
  mkdir -p "$tmp/$1/cli/platform/infra/$2" "$tmp/$1/cli/sol/lib"
  cp "$repo/cli/sol/lib/sol_cli_provider.ml" "$tmp/$1/cli/sol/lib/"
  printf '%s\n' "$3" >"$tmp/$1/cli/platform/infra/$2/$4"
}

fail=0
expect_reject() {
  if "$guard" "$tmp/$1" >/dev/null 2>&1; then
    echo "test_destroy_completeness_check: guard ACCEPTED a target root with $2." >&2
    fail=1
  fi
}
expect_accept() {
  if ! "$guard" "$tmp/$1" >/dev/null 2>&1; then
    echo "test_destroy_completeness_check: guard REJECTED a repaired target root ($2)." >&2
    fail=1
  fi
}

# 0. HARDEN-005: a provider added to the provider list has its root checked
#    without the guard being edited. The fake provider module names `azure`, and
#    the azure root carries the defect rule 1 rejects.
mk newprovider azure 'resource "aws_ecr_repository" "services" {
  name = "x"
}' main.tf
cat >"$tmp/newprovider/cli/sol/lib/sol_cli_provider.ml" <<'OCAML'
let to_string = function
  | Aws -> "aws"
  | Gcp -> "gcp"
  | Azure -> "azure"
;;
OCAML
expect_reject newprovider "a new provider's root that the hard-coded list never named"

# 1. The defect that actually stranded a live target: ECR without force_delete.
mk ecr aws 'resource "aws_ecr_repository" "services" {
  name                 = "x"
  image_tag_mutability = "MUTABLE"
}' main.tf
mk ecr gcp '' empty.tf
expect_reject ecr "an ECR repository lacking force_delete"

# 2. The latent, worse one: prevent_destroy in a target root.
mk pd aws 'resource "aws_s3_bucket" "loki" {
  bucket        = "x"
  force_destroy = true

  lifecycle {
    prevent_destroy = true
  }
}' main.tf
mk pd gcp '' empty.tf
expect_reject pd "prevent_destroy in a target root"

# 3. The GCP spelling: a bucket that is not forcibly destroyable.
mk gcpbucket aws '' empty.tf
mk gcpbucket gcp 'resource "google_storage_bucket" "loki" {
  name          = "x"
  force_destroy = false
}' main.tf
expect_reject gcpbucket "a GCP bucket with force_destroy = false"

# 4. Each provider accepts the repaired shape.
mk fixed aws 'resource "aws_ecr_repository" "services" {
  name         = "x"
  force_delete = true
}

resource "aws_s3_bucket" "loki" {
  bucket        = "x"
  force_destroy = true
}' main.tf
mk fixed gcp 'resource "google_storage_bucket" "loki" {
  name          = "x"
  force_destroy = true

  soft_delete_policy {
    retention_duration_seconds = var.gcs_soft_delete_retention_seconds
  }
}' main.tf
expect_accept fixed "both providers repaired"

# 5. DEC-045: a relinquished deletion with no residue owner is refused...
mk abandon aws '' empty.tf
mk abandon gcp 'resource "google_service_networking_connection" "sql" {
  network = "x"

  deletion_policy = "ABANDON"
}' main.tf
expect_reject abandon "an ABANDON deletion_policy with no residue annotation"

mk skip aws 'resource "aws_cloudwatch_log_group" "x" {
  name         = "x"
  skip_destroy = true
}' main.tf
mk skip gcp '' empty.tf
expect_reject skip "a skip_destroy with no residue annotation"

# ...and accepted once it names who handles what it leaves behind.
mk abandonok aws '' empty.tf
mk abandonok gcp 'resource "google_service_networking_connection" "sql" {
  network = "x"

  # residue: released by deleting the network; the destroy residue check asks for it.
  deletion_policy = "ABANDON"
}' main.tf
expect_accept abandonok "an annotated ABANDON"

# 5b. AUDIT-POST-005. `deletion_policy = "PREVENT"` is the Google provider's
#     `prevent_destroy` -- the target can never be torn down through the lifecycle,
#     which is what ADR 0004 forbids. Rule 1 cannot see it, so it has its own case.
mk prevent aws '' empty.tf
mk prevent gcp 'resource "google_compute_address" "x" {
  name            = "x"
  deletion_policy = "PREVENT"
}' main.tf
expect_reject prevent "deletion_policy = \"PREVENT\""

# A delegation the guard cannot evaluate must not pass as "not relinquishing": a
# variable could resolve to true, and the object would survive a successful destroy
# with nobody named for it.
mk skipvar aws '' empty.tf
mk skipvar gcp 'resource "google_compute_address" "x" {
  name         = "x"
  skip_destroy = var.skip_it
}' main.tf
expect_reject skipvar "a variable-driven skip_destroy"

mk dpvar aws '' empty.tf
mk dpvar gcp 'resource "google_compute_address" "x" {
  name            = "x"
  deletion_policy = var.policy
}' main.tf
expect_reject dpvar "a variable-driven deletion_policy"

# skip_delete is the same semantic spelled differently; only `true` relinquishes.
mk skipdel aws 'resource "aws_s3_bucket" "loki" {
  bucket        = "x"
  force_destroy = true
  skip_delete   = true
}' main.tf
mk skipdel gcp '' empty.tf
expect_reject skipdel "an unannotated skip_delete = true"

# ...and the classifying values are accepted, so the guard is not merely rejecting
# every mention: DELETE destroys normally, and an explicit `false` does not
# relinquish anything.
mk dpdelete aws '' empty.tf
mk dpdelete gcp 'resource "google_compute_address" "x" {
  name            = "x"
  deletion_policy = "DELETE"
}' main.tf
expect_accept dpdelete "deletion_policy = \"DELETE\""

mk skipfalse aws 'resource "aws_s3_bucket" "loki" {
  bucket        = "x"
  force_destroy = true
  skip_delete   = false
}' main.tf
mk skipfalse gcp '' empty.tf
expect_accept skipfalse "skip_delete = false"

# 6. INFRA-077: a GCS bucket without a declared soft-delete policy, or with a literal one.
mk softnone aws '' empty.tf
mk softnone gcp 'resource "google_storage_bucket" "loki" {
  name          = "x"
  force_destroy = true
}' main.tf
expect_reject softnone "a GCS bucket with no soft_delete_policy"

mk softlit aws '' empty.tf
mk softlit gcp 'resource "google_storage_bucket" "loki" {
  name          = "x"
  force_destroy = true

  soft_delete_policy {
    retention_duration_seconds = 604800
  }
}' main.tf
expect_reject softlit "a GCS bucket with a literal soft-delete retention"

# 7. A missing target root is not silently a pass.
if "$guard" "$tmp/does-not-exist" >/dev/null 2>&1; then
  echo "test_destroy_completeness_check: guard ACCEPTED a nonexistent root." >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "test_destroy_completeness_check: guard rejects ECR-without-force-delete, prevent_destroy, deletion_policy = \"PREVENT\", GCP force_destroy = false, unannotated or unclassifiable relinquished deletion (ABANDON, skip_destroy, skip_delete, variable-driven forms) and undeclared or literal GCS soft delete; accepts the repaired shapes."
