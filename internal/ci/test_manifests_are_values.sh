#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/scratch_repo.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_manifests_are_values.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkrepo() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/cli/lib/workspace" "$tmp/repo/cli/bin" "$tmp/repo/cli/test"
  scratch_repo_init "$tmp/repo"
  printf 'let d = Sol_cli_yaml.(map [ "apiVersion", string "v1" ])\n' \
    >"$tmp/repo/cli/lib/workspace/sol_cli_manifest_yaml.ml"
  printf 'let j = `Assoc [ "apiVersion", `String "v1" ]\n' >"$tmp/repo/cli/bin/cmd_ok.ml"
  printf 'let fixture = "apiVersion: apps/v1\\nkind: Deployment\\n"\n' \
    >"$tmp/repo/cli/test/test_x.ml"
}

commit() {
  git -C "$tmp/repo" add -A
  git -C "$tmp/repo" -c user.email=t@t -c user.name=t commit -qm x
}

expect() {
  local want="$1" name="$2"
  if "$CHECK" "$tmp/repo" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" != "$want" ]; then
    echo "  [FAIL] $name (expected $want, got $got)"
    exit 1
  fi
  echo "  [OK]   $name"
}

mkrepo; commit
expect pass "value-built manifests; test fixtures may be text"

mkrepo
printf 'let doc ns = Printf.sprintf {|---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: %%s|} ns\n' \
  >"$tmp/repo/cli/lib/workspace/x.ml"
commit
expect fail "a YAML template in a library"

mkrepo
printf 'let j n = Printf.sprintf {|{"apiVersion":"v1","metadata":{"name":"%%s"}}|} n\n' \
  >"$tmp/repo/cli/bin/cmd_bad.ml"
commit
expect fail "a sprintf-built JSON manifest in a command"

mkrepo
printf 'let j n = "{\\"apiVersion\\":\\"v1\\",\\"name\\":\\"" ^ n ^ "\\"}"\n' \
  >"$tmp/repo/cli/bin/cmd_bad.ml"
commit
expect fail "an escaped-string JSON manifest"
