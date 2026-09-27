#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$repo_root/internal/ci/check_terraform_output_fixture.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

mkcase() {
  local name="$1" root="$scratch/$name"
  mkdir -p "$root/cli/test/fixtures" "$root/cli/lib/cloud" "$root/internal/ci"
  cp "$repo_root/cli/test/fixtures/terraform-output-gcp-cloud.json" "$root/cli/test/fixtures/"
  cp "$repo_root/cli/lib/cloud/sol_cli_gcp_cluster.ml" "$root/cli/lib/cloud/"
  cp "$repo_root/internal/ci/test_cloud_lifecycle_offline.sh" "$root/internal/ci/"
  printf '%s' "$root"
}

reject() {
  local name="$1" root rc mutfile
  root="$(mkcase "$name")"
  mutfile="$scratch/$name.py"
  cat >"$mutfile"
  python3 "$mutfile" "$root"
  set +e
  "$guard" "$root" >"$scratch/$name.out" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: the guard accepted the '$name' mutation:" >&2
    cat "$scratch/$name.out" >&2
    exit 1
  fi
  echo "  rejected: $name -- $(grep -m1 '^FAIL' "$scratch/$name.out" || head -1 "$scratch/$name.out")"
}

accept() {
  local name="$1" root
  root="$(mkcase "$name")"
  if ! "$guard" "$root" >"$scratch/$name.out" 2>&1; then
    echo "FAIL: the guard rejected the unmutated tree ($name):" >&2
    cat "$scratch/$name.out" >&2
    exit 1
  fi
  echo "  accepted: $name (unmutated)"
}

echo "check_terraform_output_fixture.sh mutations"

mutate_fixture() {
  local case="$1" expr="$2"
  reject "$case" <<PY
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'cli/test/fixtures/terraform-output-gcp-cloud.json'
d = json.loads(p.read_text())
$expr
p.write_text(json.dumps(d, indent=2))
PY
}

mutate_fixture no-type "del d['project_id']['type']"
mutate_fixture project-is-not-a-string "d['project_id']['value'] = 42"
mutate_fixture no-project-id "del d['project_id']"
mutate_fixture sensitive-not-a-bool "d['project_id']['sensitive'] = 'false'"

reject harness-declares-its-own-shape <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'internal/ci/test_cloud_lifecycle_offline.sh'
s = p.read_text()
s = s.replace('"$REPO_ROOT/cli/test/fixtures/terraform-output-gcp-cloud.json"',
              '"$tmp/gcp-outputs.json"', 1)
p.write_text(s)
PY
reject harness-invents-the-old-shape <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'internal/ci/test_cloud_lifecycle_offline.sh'
s = p.read_text()
anchor = chr(115)+chr(101)+chr(100)+' -e ' + chr(39) + 's#sol-qual-gcp-13#sol-qual#g' + chr(39)
assert anchor in s, 'the mutation anchor is not in the harness'
q, sq = chr(34), chr(39)
invented = 'printf ' + sq + '{' + q + 'project_id' + q + ':{' + q + 'value' + q + '}}' + sq
old_line = [line for line in s.splitlines() if anchor in line][0]
s = s.replace(old_line, invented + chr(10) + old_line, 1)
assert invented in s, 'the mutation did not apply'
p.write_text(s)
PY

reject parser-reads-a-private-shape <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'cli/lib/cloud/sol_cli_gcp_cluster.ml'
s = p.read_text()
# Every occurrence, so the mutation cannot land on the comment that explains the choice and leave
# the code untouched -- which is how this case first passed.
before = s
s = s.replace('Sol_cli_cluster.outputs_reader', 'Sol_cli_gcp_private_reader')
assert s != before, 'the mutation did not apply'
p.write_text(s)
PY

accept real-tree

echo "check_terraform_output_fixture.sh: all mutations rejected, unmutated tree accepted"
