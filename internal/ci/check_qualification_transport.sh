#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(git rev-parse --show-toplevel)}"

transport="$root/internal/qualification/transport/transport.yaml"
step="$root/internal/qualification/transport/establish.sh"
config="$root/cli/lib/workspace/sol_cli_config.ml"

fail() {
  echo "check_qualification_transport: $1" >&2
  exit 1
}

for f in "$transport" "$step" "$config"; do [ -f "$f" ] || fail "missing $f"; done

quoted() { grep -oE '"[^"]+"' | tr -d '"' | sort | tr '\n' ' '; }

resources="$(grep -E '^[[:space:]]*resources:' "$transport" | quoted)"
if [ "$resources" != "pods pods/portforward services " ]; then
  fail "the qualification transport's resource set changed: '$resources'"
fi

pod_rule="$(awk '/resources: \["pods", "services"\]/{getline; print}' "$transport" | quoted)"
fwd_rule="$(awk '/resources: \["pods\/portforward"\]/{getline; print}' "$transport" | quoted)"
[ "$pod_rule" = "get list " ] || fail "the addressing rule's verbs changed: '$pod_rule' (expected get, list)"
[ "$fwd_rule" = "create " ] || fail "the transport rule's verbs changed: '$fwd_rule' (expected create)"

if grep -Eq '"(update|patch|delete|deletecollection|\*)"' "$transport"; then
  fail "the qualification transport grants a mutating verb"
fi

for dir in "$root"/platform/cloud/*/*/; do
  if grep -rqE 'sol:qualifiers|sol-qualifier-transport' "$dir" 2>/dev/null; then
    fail "a production Terraform root references the qualification transport: $dir"
  fi
done

if grep -qiE 'qualifier' "$config"; then
  fail "the target schema names a qualifier principal; qualification scaffolding must not enter the customer-facing contract"
fi

if grep -qE 'transport\.yaml' "$root/cli/lib/cloud/sol_cli_cloud_lifecycle.ml" 2>/dev/null; then
  fail "Sol's lifecycle applies the qualification transport manifest"
fi

echo "qualification transport: harness-only grant, and unreachable from the production path"
