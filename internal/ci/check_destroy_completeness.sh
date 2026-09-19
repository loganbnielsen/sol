#!/usr/bin/env bash
# ADR 0004: normal lifecycle activity must never make a target undeletable
# through the normal lifecycle.
#
# This checks the mechanical half of that invariant in the *target* roots, i.e.
# the roots `sol cloud destroy` actually tears down. Two rules:
#
#   1. No `prevent_destroy` in a target root. Terraform refuses to destroy such a
#      resource before it even attempts the delete, so one is enough to strand a
#      whole target -- and a resource that must outlive a target belongs in a
#      different root (bootstrap), not under one.
#   2. Every resource ordinary activity populates carries the provider's force
#      attribute: `force_delete` for ECR repositories (deploying pushes images
#      into them), `force_destroy` for object storage (running the platform fills
#      it with log chunks and metric blocks).
#
# Usage: check_destroy_completeness.sh [repo-root]
#
# The audit that motivated this found the class on BOTH providers, so the check
# is written against both: the invariant is the point, the attributes are just
# how AWS and GCP spell it today. It is deliberately structural rather than a
# list of resource names, so a new artifact-holding resource is covered by the
# rule rather than by someone remembering.

set -u

root="${1:-.}"
target_roots=("cli/platform/infra/aws" "cli/platform/infra/gcp")

fail=0
checked=0

report() {
  echo "check_destroy_completeness: $1" >&2
  fail=1
}

# `terraform` blocks are not HCL resources; only attribute occurrences matter, so
# match the attribute where it is assigned.
for dir in "${target_roots[@]}"; do
  if [ ! -d "$root/$dir" ]; then
    echo "check_destroy_completeness: target root '$dir' not found under '$root'." >&2
    exit 1
  fi

  for tf in "$root/$dir"/*.tf; do
    [ -e "$tf" ] || continue
    checked=$((checked + 1))

    if grep -qE '^[[:space:]]*prevent_destroy[[:space:]]*=' "$tf"; then
      report "$tf uses prevent_destroy, so a target could never be destroyed (ADR 0004)."
    fi
  done

  # ECR repositories: images arrive by publishing, which the documented lifecycle
  # does before it ever destroys.
  while IFS= read -r tf; do
    [ -n "$tf" ] || continue
    if ! grep -qE '^[[:space:]]*force_delete[[:space:]]*=[[:space:]]*true' "$tf"; then
      report "$tf declares an ECR repository without force_delete = true, so images published by the lifecycle block the teardown."
    fi
  done < <(grep -rlE '^[[:space:]]*resource[[:space:]]+"aws_ecr_repository"' "$root/$dir" --include='*.tf' 2>/dev/null)

  # Object storage: the platform writes logs and metrics into it while it runs.
  while IFS= read -r tf; do
    [ -n "$tf" ] || continue
    if ! grep -qE '^[[:space:]]*force_destroy[[:space:]]*=[[:space:]]*true' "$tf"; then
      report "$tf declares an object-storage bucket without force_destroy = true, so platform-written contents block the teardown."
    fi
  done < <(grep -rlE '^[[:space:]]*resource[[:space:]]+"(aws_s3_bucket|google_storage_bucket)"' "$root/$dir" --include='*.tf' 2>/dev/null)
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "check_destroy_completeness: $checked terraform file(s) in ${#target_roots[@]} target root(s); no prevent_destroy, every lifecycle-populated resource removable."
