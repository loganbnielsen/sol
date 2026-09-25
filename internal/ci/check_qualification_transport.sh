#!/usr/bin/env bash
set -euo pipefail

# DEC-039 / FND-0020: the qualification transport is qualification-only, and the
# production identity model is not widened for the convenience of a test.
#
# Checked in both directions:
#
#   1. the grant is transport and addressing only -- no mutating verb, no
#      pods/exec, no pods/log, no events, no secrets;
#   2. nothing in the production path can acquire it: no production Terraform root
#      references the qualifier group or its role, no target field names the
#      qualifier principal, and `sol cloud apply` never applies the manifest.
#
# (2) is the half that matters for customers: a production environment must not be
# able to obtain qualification scaffolding by running Sol's normal lifecycle.

root="${1:-$(git rev-parse --show-toplevel)}"

transport="$root/internal/pipeline/qualification/transport/transport.yaml"
step="$root/internal/pipeline/qualification/transport/establish.sh"
config="$root/cli/sol/lib/sol_cli_config.ml"

fail() {
  echo "check_qualification_transport: $1" >&2
  exit 1
}

for f in "$transport" "$step" "$config"; do [ -f "$f" ] || fail "missing $f"; done

# ── 1. the grant is transport only ───────────────────────────────────────────
# The resource set is asserted exactly, so adding a resource to the transport --
# exec, logs, events, secrets, anything -- fails here.
# The quoted tokens on each `resources:` line, sorted, so the set is compared exactly.
quoted() { grep -oE '"[^"]+"' | tr -d '"' | sort | tr '\n' ' '; }

resources="$(grep -E '^[[:space:]]*resources:' "$transport" | quoted)"
if [ "$resources" != "pods pods/portforward services " ]; then
  fail "the qualification transport's resource set changed: '$resources'"
fi

# ...and the verbs are asserted per rule, so `create` cannot spread to pods or
# services where it would be workload mutation.
pod_rule="$(awk '/resources: \["pods", "services"\]/{getline; print}' "$transport" | quoted)"
fwd_rule="$(awk '/resources: \["pods\/portforward"\]/{getline; print}' "$transport" | quoted)"
[ "$pod_rule" = "get list " ] || fail "the addressing rule's verbs changed: '$pod_rule' (expected get, list)"
[ "$fwd_rule" = "create " ] || fail "the transport rule's verbs changed: '$fwd_rule' (expected create)"

if grep -Eq '"(update|patch|delete|deletecollection|\*)"' "$transport"; then
  fail "the qualification transport grants a mutating verb"
fi

# ── 2. it cannot leak into production ────────────────────────────────────────
for dir in "$root"/platform/infra/*/; do
  if grep -rqE 'sol:qualifiers|sol-qualifier-transport' "$dir" 2>/dev/null; then
    fail "a production Terraform root references the qualification transport: $dir"
  fi
done

if grep -qiE 'qualifier' "$config"; then
  fail "the target schema names a qualifier principal; qualification scaffolding must not enter the customer-facing contract"
fi

if grep -qE 'transport\.yaml' "$root/cli/sol/lib/sol_cli_cloud_lifecycle.ml" 2>/dev/null; then
  fail "Sol's lifecycle applies the qualification transport manifest"
fi

echo "qualification transport: harness-only grant, and unreachable from the production path"
