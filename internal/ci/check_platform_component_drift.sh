#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cmd_local="$repo_root/cli/bin/cmd_local.ml"
main_tf="$repo_root/platform/cloud/modules/platform/main.tf"

migrated_keys=(
  "deploymentMode"
  "singleBinary.replicas"
  "write.replicas"
  "read.replicas"
  "backend.replicas"
  "gateway.enabled"
  "loki.auth_enabled"
  "loki.commonConfig.replication_factor"
  "loki.storage.type"
  "loki.useTestSchema"
  "sidecar.dashboards.enabled"
  "sidecar.datasources.enabled"
  "pushgateway.enabled"
  "alertmanager.enabled"
  "tls.enabled"
  "config.cluster.auto_create_topics_enabled"
  "auth.database"
)

cmd_local_only_keys=(
  "singleBinary.persistence.enabled"
  "server.persistentVolume.enabled"
  "statefulset.replicas"
  "resources.cpu.cores"
  "auth.postgresPassword"
  "primary.persistence.enabled"
)

fail=0

for key in "${migrated_keys[@]}"; do
  if grep -qF "\"${key}\"" "$cmd_local"; then
    echo "guardrail: $cmd_local hardcodes \"${key}\" inline again -- this value belongs in platform/shared/components.json (ADR 0001 / CODE_LAYER-005)." >&2
    fail=1
  fi
  if grep -qF "\"${key}\"" "$main_tf"; then
    echo "guardrail: $main_tf hardcodes \"${key}\" inline again -- this value belongs in platform/shared/components.json (ADR 0001 / CODE_LAYER-005)." >&2
    fail=1
  fi
done

for key in "${cmd_local_only_keys[@]}"; do
  if grep -qF "\"${key}\"" "$cmd_local"; then
    echo "guardrail: $cmd_local hardcodes \"${key}\" inline again -- this value now comes entirely from the local layer of platform/shared/components.json (ADR 0001 / CODE_LAYER-005); main.tf legitimately keeps its own var-driven \`set\` for this key, but cmd_local.ml has no such var and must not duplicate it." >&2
    fail=1
  fi
done

components_json="$repo_root/platform/shared/components.json"
if ! bad_layers="$(python3 - "$components_json" <<'PY'
import json, sys
want = {"common", "local", "durable"}
data = json.load(open(sys.argv[1]))
for component, layers in sorted(data.items()):
    if not isinstance(layers, dict) or set(layers) != want:
        got = sorted(layers) if isinstance(layers, dict) else type(layers).__name__
        print(f"{component}: {got}")
PY
)"; then
  echo "guardrail: $components_json could not be read" >&2
  fail=1
elif [ -n "$bad_layers" ]; then
  echo "guardrail: every component in $components_json must have exactly the layers common, local, durable (keyed by profile, never by env, provider or region):" >&2
  printf '  %s\n' "$bad_layers" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "guardrail: no migrated platform-component keys found duplicated inline in cmd_local.ml or main.tf."
fi

exit "$fail"
