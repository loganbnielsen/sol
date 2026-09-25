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

mk() {
  # mk <dir> <file> <contents>
  mkdir -p "$tmp/$1/cli/platform/infra/$2"
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

# 6. A missing target root is not silently a pass.
if "$guard" "$tmp/does-not-exist" >/dev/null 2>&1; then
  echo "test_destroy_completeness_check: guard ACCEPTED a nonexistent root." >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "test_destroy_completeness_check: guard rejects ECR-without-force-delete, prevent_destroy, GCP force_destroy = false and unannotated relinquished deletion; accepts the repaired shapes."
