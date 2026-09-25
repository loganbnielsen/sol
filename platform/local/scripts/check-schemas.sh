#!/usr/bin/env bash
# CI schema compatibility check.
#
# For each schema file in platform/local/schemas/, runs two checks:
#   1. Registry compatibility check — catches type changes (via Redpanda API)
#   2. Structural check — catches required field removals (client-side, Python)
#      Redpanda's JSON Schema compatibility does not catch this case.
#
# Exits 1 if any schema would be a breaking change; exits 0 if all are safe.
#
# Usage:
#   SCHEMA_REGISTRY_URL=http://localhost:8081 ./platform/local/scripts/check-schemas.sh
set -euo pipefail

REGISTRY="${SCHEMA_REGISTRY_URL:-http://localhost:8081}"
SCHEMAS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../schemas" && pwd)"

if [[ ! -d "$SCHEMAS_DIR" ]]; then
  echo "No schemas directory found at $SCHEMAS_DIR — nothing to check."
  exit 0
fi

fail=0

# Python helper: structural compatibility check between two JSON Schemas.
# Catches: required field removals, required field type changes.
# These are not caught by Redpanda's JSON Schema compatibility implementation.
check_structural_compat() {
  local old_schema="$1"
  local new_schema="$2"
  python3 - "$old_schema" "$new_schema" <<'PYEOF'
import json, sys

old = json.loads(sys.argv[1])
new = json.loads(sys.argv[2])

old_required = set(old.get("required", []))
new_required = set(new.get("required", []))
old_props    = old.get("properties", {})
new_props    = new.get("properties", {})

errors = []

# Required field removed
for field in old_required - new_required:
    errors.append(f"required field '{field}' removed or made optional")

# Required field type changed
for field in old_required & new_required:
    old_type = old_props.get(field, {}).get("type")
    new_type = new_props.get(field, {}).get("type")
    if old_type and new_type and old_type != new_type:
        errors.append(f"required field '{field}' type changed: {old_type} → {new_type}")

if errors:
    for e in errors:
        print(f"  BREAKING: {e}")
    sys.exit(1)
sys.exit(0)
PYEOF
}

for schema_file in "$SCHEMAS_DIR"/*.json; do
  [[ -e "$schema_file" ]] || { echo "No schema files in $SCHEMAS_DIR."; break; }

  subject="$(basename "$schema_file" .json)"
  new_schema_content="$(cat "$schema_file")"

  # Check whether a previous version exists.
  http_status=$(curl -s -o /tmp/compat_existing.json -w "%{http_code}" \
    "${REGISTRY}/subjects/${subject}/versions/latest")

  if [[ "$http_status" == "404" ]]; then
    echo "[NEW]  $subject — no existing version, first registration will succeed."
    continue
  fi

  if [[ "$http_status" != "200" ]]; then
    echo "[ERR]  $subject — registry returned HTTP $http_status"
    fail=1
    continue
  fi

  # --- Check 1: Registry compatibility (catches type changes) ---
  body=$(printf '{"schemaType":"JSON","schema":%s}' \
    "$(echo "$new_schema_content" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")

  compat_response=$(curl -s -X POST \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d "$body" \
    "${REGISTRY}/compatibility/subjects/${subject}/versions/latest")

  is_compatible=$(echo "$compat_response" | python3 -c \
    'import json,sys; d=json.load(sys.stdin); print(d.get("is_compatible","false"))' 2>/dev/null || echo "false")

  registry_ok=true
  if [[ "$is_compatible" != "True" && "$is_compatible" != "true" ]]; then
    registry_ok=false
  fi

  # --- Check 2: Structural check (catches required field removals) ---
  old_schema_content=$(python3 -c \
    'import json,sys; d=json.load(open("/tmp/compat_existing.json")); print(d.get("schema","{}"))' 2>/dev/null || echo "{}")

  structural_ok=true
  structural_errors=""
  if ! structural_errors=$(check_structural_compat "$old_schema_content" "$new_schema_content" 2>&1); then
    structural_ok=false
  fi

  # --- Report ---
  if $registry_ok && $structural_ok; then
    echo "[OK]   $subject — compatible with current version."
  else
    echo "[FAIL] $subject — BREAKING CHANGE detected:"
    if ! $registry_ok; then
      echo "  Registry check: incompatible (response: $compat_response)"
    fi
    if ! $structural_ok; then
      echo "$structural_errors"
    fi
    fail=1
  fi
done

echo ""
if [[ $fail -ne 0 ]]; then
  echo "Schema check FAILED — fix breaking changes before deploying."
  exit 1
fi

echo "Schema check passed — safe to deploy."
exit 0
