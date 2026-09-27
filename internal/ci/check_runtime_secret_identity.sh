#!/usr/bin/env bash
# INFRA-040: the substrate's Secret and the migration Job's reference must be the
# same identity.
#
# The defect: [secret_doc]'s template appended `-secrets` to the name it was handed,
# and the substrate handed it the already-final [runtime_secret_name], so the Secret
# created was `sol-secrets-secrets` while every consumer referenced `sol-secrets`.
# Every migration Job's container failed with CreateContainerConfigError, so the
# migration gate could never pass and no workload could be deployed at all.
#
# Both halves are rendered assertions (cli/test/test_runtime_secret_identity.ml):
# the substrate's Secret, and -- since REFAC-131 moved the migration Job's builder
# into the library, and REFAC-139 the runner that submits it, -- the Job's secretRef. What this adds is that the code paths
# the binary runs are the ones those tests render: the substrate names the Secret
# from the shared constant, and `sol migrate` renders its Job through the tested
# builder rather than a template of its own.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
substrate="$root/cli/lib/deploy/sol_cli_substrate.ml"
migrate="$root/cli/lib/deploy/sol_cli_migration_job.ml"
manifest="$root/cli/lib/workspace/sol_cli_manifest_yaml.ml"

fail=0
require() {
  # require <description> <file> <pattern>
  local description="$1" file="$2" pattern="$3"
  if ! grep -qE "$pattern" "$file"; then
    echo "check_runtime_secret_identity: $description" >&2
    echo "  expected $file to match /$pattern/" >&2
    fail=1
  fi
}

# The substrate creates the shared runtime Secret, by that identity and no other.
require "the substrate does not name the runtime Secret from the shared constant" \
  "$substrate" '^[[:space:]]*~name:Sol_cli_manifest\.runtime_secret_name$'

# The consumer renders its Job through the tested builder, whose secretRef is that
# same constant, so the two cannot diverge.
require "the migration Job runner does not render its Job through Sol_cli_manifest.migration_job_doc" \
  "$migrate" 'Sol_cli_manifest\.migration_job_doc'
require "the migration Job builder does not reference the shared runtime Secret" \
  "$manifest" '"secretRef", Y\.map \[ "name", Y\.string runtime_secret_name \]'

# And the convention that DOES append a suffix has exactly one home, so a template
# cannot invent one for a caller that did not ask for it.
require "the workload suffix does not have a single home" \
  "$manifest" 'let workload_secret_name name ='

if [ "$fail" -ne 0 ]; then
  echo "check_runtime_secret_identity: the substrate Secret and the migration reference could disagree" >&2
  exit 1
fi

echo "check_runtime_secret_identity: substrate Secret and migration reference resolve the same identity"
