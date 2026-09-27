#!/usr/bin/env bash
# INFRA-091 / FND-0063: one representation of Terraform's output payload, used by everything.
#
# Attempt 13's defect was not a wrong constant; it was two artefacts agreeing with each other and
# with neither Terraform nor reality: the product invented a shape, and the harness stub served the
# same invented shape, so the scenario stayed green while every real run stopped. A test that
# invents the other side of an external contract cannot detect a wrong belief about that contract.
#
# This guard keeps the three consumers tied to one captured payload:
#
#   1. the fixture is Terraform's own record shape -- the values and their `sensitive`/`type`/`value`
#      fields, as `terraform output -json` publishes them;
#   2. the lifecycle harness *renders that fixture* rather than declaring an output payload of its
#      own, and the invented shape does not come back;
#   3. the product reads outputs through the reader Sol already uses for every other output
#      (`Sol_cli_cluster.outputs_reader`), not through a private second idea of the shape.
#
# Usage: internal/ci/check_terraform_output_fixture.sh [repo-root]
set -euo pipefail

root="${1:-.}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: this check needs python3" >&2
  exit 1
fi

fixture="$root/cli/test/fixtures/terraform-output-gcp-cloud.json"
harness="$root/internal/ci/test_cloud_lifecycle_offline.sh"
parser="$root/cli/lib/cloud/sol_cli_gcp_cluster.ml"

for path in "$fixture" "$harness" "$parser"; do
  if [ ! -f "$path" ]; then
    echo "FAIL: missing $path" >&2
    exit 1
  fi
done

python3 - "$fixture" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1]))
problems = []
if not isinstance(payload, dict) or not payload:
    problems.append('the fixture is not a non-empty object')
for name, entry in payload.items():
    if not isinstance(entry, dict):
        problems.append(f'{name} is not a terraform output record')
        continue
    if sorted(entry) != ['sensitive', 'type', 'value']:
        problems.append(f'{name} carries {sorted(entry)}, not terraform\'s sensitive/type/value')
        continue
    if not isinstance(entry['value'], str) or not entry['value'].strip():
        problems.append(f'{name}\'s value is not a non-blank string')
    if not isinstance(entry['type'], str):
        problems.append(f'{name}\'s type is not a string')
    if not isinstance(entry['sensitive'], bool):
        problems.append(f'{name}\'s sensitive flag is not a boolean')
if 'project_id' not in payload:
    problems.append('the fixture does not carry project_id')
if problems:
    for problem in problems:
        print('FAIL: ' + problem)
    sys.exit(1)
PY

# 2. the harness renders the fixture, and the invented shape stays gone
if ! grep -qF 'cli/test/fixtures/terraform-output-gcp-cloud.json' "$harness"; then
  echo "FAIL: the lifecycle harness does not serve the captured fixture, so its outputs payload is" >&2
  echo "      a second, hand-written idea of terraform's shape (this is what hid FND-0063)." >&2
  exit 1
fi
# Comments are allowed to name the shape they explain; code is not allowed to carry it.
# No `grep -q` in this pipeline: it exits on the first match, the upstream grep takes SIGPIPE, and
# under `pipefail` the condition reads as false -- a guard that can never fire. The output is
# discarded instead, so both greps run to completion.
if grep -vE '^[[:space:]]*#' "$harness" | grep -F '"project_id":{"value"' >/dev/null; then
  echo "FAIL: the invented single-field output shape is back in the lifecycle harness." >&2
  exit 1
fi

# 3. the product reads outputs through the reader it already uses everywhere else
# Code only again: the parser's own comment names the reader to explain the choice.
if ! grep -vE '^[[:space:]]*#' "$parser" | grep -F 'Sol_cli_cluster.outputs_reader' >/dev/null; then
  echo "FAIL: project_id_of_outputs_json does not read through Sol_cli_cluster.outputs_reader," >&2
  echo "      so Sol has a second, private idea of terraform's output shape." >&2
  exit 1
fi

echo "terraform output contract: the fixture carries terraform's fields, the harness renders it,"
echo "                          and the parser reads through Sol_cli_cluster.outputs_reader"
