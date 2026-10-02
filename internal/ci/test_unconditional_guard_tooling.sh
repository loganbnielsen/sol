#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/internal/ci/check_unconditional_guard_tooling.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

expect() {
  local want="$1" name="$2" fixture="$3"
  if python3 "$GUARD" "$fixture" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" != "$want" ]; then
    echo "  [FAIL] $name (expected $want, got $got)"
    exit 1
  fi
  echo "  [OK]   $name"
}

make_fixture() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$dest/.github/workflows"
  cp "$ROOT/.github/workflows/ci.yml" "$dest/.github/workflows/ci.yml"
  cp -r "$ROOT/internal" "$dest/internal"
}

mutate() {
  local workflow="$1" step_name="$2" change="$3"
  python3 - "$workflow" "$step_name" "$change" <<'PY'
import sys

import yaml

path, step_name, change = sys.argv[1], sys.argv[2], sys.argv[3]
workflow = yaml.safe_load(open(path))
for step in workflow["jobs"]["test"]["steps"]:
    if not str(step.get("name", "")).startswith(step_name):
        continue
    if change == "clear-run":
        step["run"] = "true"
    elif change == "gate":
        step["if"] = "false"
    elif change == "subset":
        step["run"] = "opam exec -- dune build internal/tooling/soldev/bin/main.exe"
    elif change == "mention-only":
        step["run"] = "echo kubectl version --client"
    else:
        raise SystemExit(f"unknown change {change}")
open(path, "w").write(yaml.safe_dump(workflow, sort_keys=False))
PY
}

echo "unconditional-guard tooling (BUG-064)"
expect pass "the real workflow provides every unconditional guard's tooling" "$ROOT"

make_fixture "$tmp/without"
mutate "$tmp/without/.github/workflows/ci.yml" "Tooling for the unconditional guards" clear-run
expect fail "a workflow that no longer builds the tooling is rejected" "$tmp/without"

make_fixture "$tmp/gated"
mutate "$tmp/gated/.github/workflows/ci.yml" "Pipeline ticket validation guard" gate
expect fail "a workflow that gates the ticket-validation guard is rejected" "$tmp/gated"

make_fixture "$tmp/tool"
mutate "$tmp/tool/.github/workflows/ci.yml" "Install pinned kubectl" gate
expect fail "a workflow that gates a tool an unconditional guard requires is rejected" "$tmp/tool"

make_fixture "$tmp/mention"
mutate "$tmp/mention/.github/workflows/ci.yml" "Install pinned kubectl" mention-only
expect fail "a workflow that only mentions the tool is rejected" "$tmp/mention"

make_fixture "$tmp/renamed"
mutate "$tmp/renamed/.github/workflows/ci.yml" "Tooling for the unconditional guards" subset
expect fail "a subset that omits full-path guard binaries is rejected" "$tmp/renamed"

echo "unconditional-guard tooling: all expectations hold."
