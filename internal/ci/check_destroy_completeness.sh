#!/usr/bin/env bash

set -u

root="${1:-.}"
# shellcheck source=providers.sh
. "$(dirname "$0")/providers.sh"
providers="$(sol_providers "$root")" || {
  echo "check_destroy_completeness: could not read the provider list" >&2
  exit 1
}
target_roots=()
for provider in $providers; do
  if [ -d "$root/platform/cloud/$provider/cluster" ]; then
    target_roots+=("platform/cloud/$provider/cluster")
  fi
done
if [ "${#target_roots[@]}" -eq 0 ]; then
  echo "check_destroy_completeness: no provider has a cluster root under '$root/platform/cloud'; a check of nothing is not a pass." >&2
  exit 1
fi

fail=0
checked=0

report() {
  echo "check_destroy_completeness: $1" >&2
  fail=1
}

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

  while IFS= read -r tf; do
    [ -n "$tf" ] || continue
    if ! grep -qE '^[[:space:]]*force_delete[[:space:]]*=[[:space:]]*true' "$tf"; then
      report "$tf declares an ECR repository without force_delete = true, so images published by the lifecycle block the teardown."
    fi
  done < <(grep -rlE '^[[:space:]]*resource[[:space:]]+"aws_ecr_repository"' "$root/$dir" --include='*.tf' 2>/dev/null)

  while IFS= read -r tf; do
    [ -n "$tf" ] || continue
    if ! grep -qE '^[[:space:]]*force_destroy[[:space:]]*=[[:space:]]*true' "$tf"; then
      report "$tf declares an object-storage bucket without force_destroy = true, so platform-written contents block the teardown."
    fi
  done < <(grep -rlE '^[[:space:]]*resource[[:space:]]+"(aws_s3_bucket|google_storage_bucket)"' "$root/$dir" --include='*.tf' 2>/dev/null)

  for guard_var in $(
    grep -hoE '^[[:space:]]*deletion_protection[[:space:]]*=[[:space:]]*var\.[a-z_]+' \
      "$root/$dir"/*.tf 2>/dev/null \
      | sed 's/.*var\.//' \
      | sort -u
  ); do
    if ! grep -qE "\"$guard_var\",[[:space:]]*\"false\"" "$root/cli/lib/cloud/sol_cli_provider_capabilities.ml"; then
      report "$dir routes $guard_var through a variable, but no provider's Destroy policy (Sol_cli_provider_capabilities.destroy_guard_vars) lifts it -- so a target Sol provisioned cannot be destroyed through Sol (ADR 0004)."
    fi
  done

  for tf in "$root/$dir"/*.tf; do
    [ -e "$tf" ] || continue
    while IFS=: read -r line body; do
      [ -n "$line" ] || continue
      value="$(printf '%s' "$body" \
        | sed 's/#.*//; s/.*=[[:space:]]*//; s/[[:space:]]*$//; s/\r$//')"
      key="$(printf '%s' "$body" | sed 's/^[[:space:]]*//; s/[[:space:]]*=.*//')"
      case "$key:$value" in
        deletion_policy:\"ABANDON\"|skip_destroy:true|skip_delete:true)
          address="$(head -n "$line" "$tf" \
            | grep -oE '^resource[[:space:]]+"[^"]+"[[:space:]]+"[^"]+"' \
            | tail -1 \
            | sed -E 's/^resource[[:space:]]+"([^"]+)"[[:space:]]+"([^"]+)"/\1.\2/')"
          provider="${dir#platform/cloud/}"
          provider="${provider%%/*}"
          residue="$root/cli/lib/cloud/sol_cli_${provider}_destruction.ml"
          if [ -z "$address" ] || ! grep -qF "\"$address\"" "$residue" 2>/dev/null; then
            report "$tf:$line relinquishes deletion of ${address:-a resource} (Terraform will not delete the remote object), but no residue probe in cli/lib/cloud/sol_cli_${provider}_destruction.ml names it: register one in relinquished_residue_probes (DEC-045)."
          fi
          ;;
        deletion_policy:\"PREVENT\")
          report "$tf:$line sets deletion_policy = \"PREVENT\", which no Destroy policy can lift: a target Sol provisioned could never be destroyed (ADR 0004)."
          ;;
        deletion_policy:\"DELETE\"|skip_destroy:false|skip_delete:false) ;;
        *)
          report "$tf:$line sets $key to '$value', a deletion semantic this guard cannot classify; declare the value explicitly (and, if it relinquishes the remote object, register its residue probe) so the invariant does not rest on a value the check cannot read."
          ;;
      esac
    done < <(grep -nE '^[[:space:]]*(deletion_policy|skip_destroy|skip_delete)[[:space:]]*=' "$tf")
  done

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

  if grep -qE '^[[:space:]]*deletion_protection[[:space:]]*=[[:space:]]*(true|false)' "$root/$dir"/*.tf 2>/dev/null; then
    report "$dir sets deletion_protection to a literal, which no Destroy policy can override; route it through a variable."
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "check_destroy_completeness: $checked terraform file(s) in ${#target_roots[@]} target root(s); no prevent_destroy or deletion_policy = \"PREVENT\", no literal deletion guard, every lifecycle-populated resource removable, every routed guard liftable by the Destroy policy, every relinquished deletion classified and covered by a residue probe, and every GCS bucket's soft delete declared."
