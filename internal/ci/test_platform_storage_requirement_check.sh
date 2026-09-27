#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$repo_root/internal/ci/check_platform_storage_requirement.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

mkcase() {
  local name="$1" root="$scratch/$name"
  mkdir -p "$root/cli/lib/cloud" "$root/platform/cloud"
  cp -r "$repo_root/platform/cloud/modules" "$root/platform/cloud/modules"
  cp -r "$repo_root/platform/cloud/gcp" "$root/platform/cloud/gcp"
  cp "$repo_root/cli/lib/cloud/sol_cli_platform_storage.ml" "$root/cli/lib/cloud/"
  printf '%s' "$root"
}

reject() {
  local name="$1" root rc mutfile
  root="$(mkcase "$name")"
  mutfile="$scratch/$name.mutation.py"
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

echo "check_platform_storage_requirement.sh mutations"

reject no-provenance <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'cli/lib/cloud/sol_cli_platform_storage.ml'
s = p.read_text()
s = s.replace('; provenance =\n        "chart default for Loki', '; provenance =\n        "" , "chart default for Loki', 1)
p.write_text(s)
PY

reject claims-a-sol-size <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'cli/lib/cloud/sol_cli_platform_storage.ml'
s = p.read_text()
s = s.replace('"chart default for the prometheus server', '"var.prometheus_persistent_storage default for the prometheus server', 1)
p.write_text(s)
PY

reject provenance-without-attribution <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]) / 'cli/lib/cloud/sol_cli_platform_storage.ml'
s = p.read_text()
# The formatter wraps long string literals with continuations, so the anchor has to tolerate
# whitespace and line breaks -- and must fail loudly when it does not match, because a silently
# no-op mutation is an accepted tree wearing a rejected case's name.
mutated, count = re.subn(r'"chart default for the prometheus server[^"]*"',
                         '"a number with no stated source"', s, count=1)
assert count == 1, 'the mutation anchor did not match the declaration'
p.write_text(mutated)
PY

reject loki-persistence-disabled <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'platform/cloud/modules/platform/main.tf'
s = p.read_text()
assert 'singleBinary.persistence.enabled' in s
# Target the set block, not the comment that names the same value.
s = s.replace('name  = "singleBinary.persistence.enabled"', 'name  = "singleBinary.persistence.removed"', 1)
p.write_text(s)
PY

accept real-tree

echo "check_platform_storage_requirement.sh: all mutations rejected, unmutated tree accepted"
