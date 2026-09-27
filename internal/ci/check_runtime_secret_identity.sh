#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
substrate="$root/cli/lib/deploy/sol_cli_substrate.ml"
migrate="$root/cli/lib/deploy/sol_cli_migration_job.ml"
manifest="$root/cli/lib/workspace/sol_cli_manifest_yaml.ml"

fail=0
require() {
  local description="$1" file="$2" pattern="$3"
  if ! grep -qE "$pattern" "$file"; then
    echo "check_runtime_secret_identity: $description" >&2
    echo "  expected $file to match /$pattern/" >&2
    fail=1
  fi
}

require "the substrate does not name the runtime Secret from the shared constant" \
  "$substrate" '^[[:space:]]*~name:Sol_cli_manifest\.runtime_secret_name$'

require "the migration Job runner does not render its Job through Sol_cli_manifest.migration_job_doc" \
  "$migrate" 'Sol_cli_manifest\.migration_job_doc'
require "the migration Job builder does not reference the shared runtime Secret" \
  "$manifest" '"secretRef", Y\.map \[ "name", Y\.string runtime_secret_name \]'

require "the workload suffix does not have a single home" \
  "$manifest" 'let workload_secret_name name ='

if [ "$fail" -ne 0 ]; then
  echo "check_runtime_secret_identity: the substrate Secret and the migration reference could disagree" >&2
  exit 1
fi

echo "check_runtime_secret_identity: substrate Secret and migration reference resolve the same identity"
