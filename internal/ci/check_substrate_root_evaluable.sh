#!/bin/bash
set -euo pipefail

ROOT="${1:-.}"
DIR="$ROOT/platform/cloud/gcp/cluster"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$DIR"/*.tf "$WORK/"
cd "$WORK"

python3 - "$WORK/main.tf" <<'PYEOF'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
start = text.index('  backend "')
depth = 0
index = start
while index < len(text):
    if text[index] == "{":
        depth += 1
    elif text[index] == "}":
        depth -= 1
        if depth == 0:
            break
    index += 1
line_start = text.rindex("\n", 0, start) + 1
path.write_text(text[:line_start] + text[index + 1 :])
PYEOF

terraform init -backend=false -input=false -no-color >/dev/null

ask() {
  printf '%s\n' "$1" | terraform console -no-color "${@:2}" 2>&1 | tail -1
}

fail=0

off="$(
  ask local.needs_kubernetes -var=in_cluster_layer=false -var=provisioner_bootstrap_admin=true |
    tr -d '[:space:]'
)"
if [ "$off" != "false" ]; then
  echo "check_substrate_root_evaluable: with the in-cluster layer off, needs_kubernetes read '$off' (expected false)" >&2
  fail=1
fi

for local in kubernetes_host kubernetes_token kubernetes_cluster_ca_certificate; do
  value="$(
    ask "local.$local" -var=in_cluster_layer=false -var=provisioner_bootstrap_admin=true |
      tr -d '[:space:]'
  )"
  if [ "$value" != '""' ]; then
    echo "check_substrate_root_evaluable: with the in-cluster layer off, local.$local read '$value' (expected a known empty string, so the provider configuration stays evaluable)" >&2
    fail=1
  fi
done

on="$(ask local.needs_kubernetes -var=in_cluster_layer=true -var=provisioner_bootstrap_admin=true | tr -d '[:space:]')"
if [ "$on" != "true" ]; then
  echo "check_substrate_root_evaluable: with both gates on, needs_kubernetes read '$on' (expected true)" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "check_substrate_root_evaluable: the cluster root's Kubernetes provider is a known empty value with the in-cluster layer off, and required when it is on"
