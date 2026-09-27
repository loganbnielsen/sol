#!/usr/bin/env bash
# Mutations for check_gcp_standard_substrate.sh (INFRA-093). Each case breaks one tie the guard
# holds; every mutation asserts that it actually applied, because a mutation that silently no-ops
# is an accepted tree wearing a rejected case's name.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$repo_root/internal/ci/check_gcp_standard_substrate.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

mkcase() {
  local name="$1" root="$scratch/$name"
  mkdir -p "$root/platform/cloud/gcp/cluster" "$root/cli/lib/config"
  cp "$repo_root/platform/cloud/gcp/cluster/main.tf" "$root/platform/cloud/gcp/cluster/"
  cp "$repo_root/platform/cloud/gcp/cluster/variables.tf" "$root/platform/cloud/gcp/cluster/"
  printf '%s' "$root"
}

reject() {
  local name="$1" root rc mutfile before after
  root="$(mkcase "$name")"
  mutfile="$scratch/$name.py"
  cat >"$mutfile"
  # A mutation that does not change the tree is an accepted tree wearing a rejected case's name,
  # which is how two of these cases first "passed". The digests make that impossible to miss, for
  # every case, whatever its own assertions say.
  before="$(find "$root" -type f -exec cat {} + | cksum)"
  python3 "$mutfile" "$root"
  after="$(find "$root" -type f -exec cat {} + | cksum)"
  if [ "$before" = "$after" ]; then
    echo "FAIL: the '$name' mutation did not change the tree at all" >&2
    exit 1
  fi
  set +e
  "$guard" "$root" >"$scratch/$name.out" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: the guard accepted the '$name' mutation:" >&2
    cat "$scratch/$name.out" >&2
    exit 1
  fi
  echo "  rejected: $name -- $(grep -m1 '^FAIL' "$scratch/$name.out" | cut -c1-90)"
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

echo "check_gcp_standard_substrate.sh mutations"

reject autopilot-requested <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]) / 'platform/cloud/gcp/cluster/main.tf'
s = p.read_text()
s2, n = re.subn(r'^(\s*)remove_default_node_pool\s*=\s*true\s*$',
                r'\1enable_autopilot = true\n\1remove_default_node_pool = true', s, count=1, flags=re.M)
assert n == 1, 'the mutation anchor did not match'
p.write_text(s2)
PY

reject autopilot-becomes-a-knob <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]) / 'platform/cloud/gcp/cluster/main.tf'
s = p.read_text()
s2, n = re.subn(r'^(\s*)remove_default_node_pool\s*=\s*true\s*$',
                r'\1enable_autopilot = var.enable_autopilot\n\1remove_default_node_pool = true',
                s, count=1, flags=re.M)
assert n == 1, 'the mutation anchor did not match'
p.write_text(s2)
PY

reject node-pool-removed <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'platform/cloud/gcp/cluster/main.tf'
s = p.read_text()
nl = chr(10)
begin = s.index('resource "google_container_node_pool"')
finish = s.index(nl + '}' + nl, begin) + len(nl + '}' + nl)
s = s[:begin] + s[finish:]
assert 'resource "google_container_node_pool"' not in s, 'the mutation did not remove the pool resource'
p.write_text(s)
PY

reject machine-type-hard-coded <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]) / 'platform/cloud/gcp/cluster/main.tf'
s = p.read_text()
s2, n = re.subn(r'machine_type\s*=\s*var\.node_machine_type',
                'machine_type = "e2-standard-2"', s, count=1)
assert n == 1, 'the mutation anchor did not match'
p.write_text(s2)
PY

reject sizing-became-target-configuration <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
p = root / 'cli/lib/config' / 'sol_cli_config.ml'
p.write_text('type node_pool = { node_count : int; node_machine_type : string }')
assert p.read_text() != '', 'the mutation did not write the target key'

PY

reject control-plane-became-zonal <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]) / 'platform/cloud/gcp/cluster/main.tf'
s = p.read_text()
s2, n = re.subn(r'location\s*=\s*var\.region', 'location = "${var.region}-a"', s, count=1)
assert n == 1, 'the mutation anchor did not match'
p.write_text(s2)
PY

accept real-tree

echo "check_gcp_standard_substrate.sh: all mutations rejected, unmutated tree accepted"
