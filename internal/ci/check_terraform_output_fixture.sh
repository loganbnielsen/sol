#!/usr/bin/env bash
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

if ! grep -qF 'cli/test/fixtures/terraform-output-gcp-cloud.json' "$harness"; then
  echo "FAIL: the lifecycle harness does not serve the captured fixture, so its outputs payload is" >&2
  echo "      a second, hand-written idea of terraform's shape (this is what hid FND-0063)." >&2
  exit 1
fi
if grep -vE '^[[:space:]]*#' "$harness" | grep -F '"project_id":{"value"' >/dev/null; then
  echo "FAIL: the invented single-field output shape is back in the lifecycle harness." >&2
  exit 1
fi

if ! grep -vE '^[[:space:]]*#' "$parser" | grep -F 'Sol_cli_cluster.outputs_reader' >/dev/null; then
  echo "FAIL: project_id_of_outputs_json does not read through Sol_cli_cluster.outputs_reader," >&2
  echo "      so Sol has a second, private idea of terraform's output shape." >&2
  exit 1
fi

echo "terraform output contract: the fixture carries terraform's fields, the harness renders it,"
echo "                          and the parser reads through Sol_cli_cluster.outputs_reader"
