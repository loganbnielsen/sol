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

  # 3. A *provider-level* deletion guard must be routed through a variable, and the
  #    Destroy policy must lift it. This is the rule live attempt 1 earned.
  #    `google_container_cluster`'s `deletion_protection` defaults to true in the
  #    provider, so a root that never mentions it still cannot be destroyed -- rule 1
  #    cannot see that, because there is no `prevent_destroy` to find. The guard is
  #    *absent* rather than wrong, which is the harder half of the invariant: it says
  #    "every destruction guard must have a documented Destroy-policy transition",
  #    not "find these dangerous declarations".
  #
  #    Requiring the assignment to be a variable is what makes a provider's default
  #    explicit and therefore visible here at all; requiring the policy to name the
  #    variable is what makes the teardown able to lift it.
  for guard_var in $(
    grep -hoE '^[[:space:]]*deletion_protection[[:space:]]*=[[:space:]]*var\.[a-z_]+' \
      "$root/$dir"/*.tf 2>/dev/null \
      | sed 's/.*var\.//' \
      | sort -u
  ); do
    if ! grep -qE "\"$guard_var\",[[:space:]]*\"false\"" "$root/cli/sol/lib/sol_cli_provider_capabilities.ml"; then
      report "$dir routes $guard_var through a variable, but no provider's Destroy policy (Sol_cli_provider_capabilities.destroy_guard_vars) lifts it -- so a target Sol provisioned cannot be destroyed through Sol (ADR 0004)."
    fi
  done

  # 4. DEC-045: an attribute that tells Terraform NOT to delete the remote object
  #    (`deletion_policy = "ABANDON"`, `skip_destroy`, `skip_delete`) means a
  #    successful destroy with an empty state still leaves that object behind. That
  #    is the one case where Terraform's destroy is deliberately not the authority
  #    for absence, so it must say who is: a `# residue:` comment within the three
  #    lines above the attribute, naming the residue handling. An unannotated one is
  #    residue nobody owns.
  for tf in "$root/$dir"/*.tf; do
    [ -e "$tf" ] || continue
    while IFS=: read -r line _; do
      [ -n "$line" ] || continue
      start=$((line > 3 ? line - 3 : 1))
      if ! sed -n "${start},$((line - 1))p" "$tf" | grep -qE '^[[:space:]]*#[[:space:]]*residue:'; then
        report "$tf:$line relinquishes deletion (Terraform will not delete the remote object) without a '# residue:' comment naming who handles what it leaves behind (DEC-045)."
      fi
    done < <(grep -nE '^[[:space:]]*(deletion_policy[[:space:]]*=[[:space:]]*"ABANDON"|skip_destroy[[:space:]]*=[[:space:]]*true|skip_delete[[:space:]]*=[[:space:]]*true)' "$tf")
  done

  # 5. INFRA-077 / FND-0057: Cloud Storage soft-deletes and bills deleted objects by
  #    default, so a destroy that reports "nothing retained" could leave billed data
  #    behind. Every target-root GCS bucket declares its soft-delete policy, with the
  #    retention routed through a variable (Sol sets it from destroy_retention).
  for tf in "$root/$dir"/*.tf; do
    [ -e "$tf" ] || continue
    buckets="$(grep -cE '^[[:space:]]*resource[[:space:]]+"google_storage_bucket"[[:space:]]' "$tf" || true)"
    [ "$buckets" -gt 0 ] || continue
    policies="$(grep -cE '^[[:space:]]*soft_delete_policy[[:space:]]*\{' "$tf" || true)"
    if [ "$policies" -lt "$buckets" ]; then
      report "$tf declares $buckets GCS bucket(s) but $policies soft_delete_policy block(s); Cloud Storage would soft-delete and bill their contents after a destroy (INFRA-077)."
    fi
    if grep -qE '^[[:space:]]*retention_duration_seconds[[:space:]]*=[[:space:]]*[0-9]' "$tf"; then
      report "$tf sets a GCS soft-delete retention to a literal; route it through a variable so destroy_retention decides it (INFRA-077)."
    fi
  done

  # ...and a literal is a guard no Destroy policy can override.
  if grep -qE '^[[:space:]]*deletion_protection[[:space:]]*=[[:space:]]*(true|false)' "$root/$dir"/*.tf 2>/dev/null; then
    report "$dir sets deletion_protection to a literal, which no Destroy policy can override; route it through a variable."
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "check_destroy_completeness: $checked terraform file(s) in ${#target_roots[@]} target root(s); no prevent_destroy, no literal deletion guard, every lifecycle-populated resource removable, every routed guard liftable by the Destroy policy, every relinquished deletion annotated with its residue handling, and every GCS bucket's soft delete declared."
