#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_json_decode_boundary.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkrepo() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/cli/lib/deploy" "$tmp/repo/cli/bin" "$tmp/repo/cli/test"
  git -C "$tmp/repo" init -q
  printf 'let n j = Sol_cli_json.field [ "metadata"; "name" ] j |> Sol_cli_json.string\n' \
    >"$tmp/repo/cli/lib/deploy/a.ml"
  printf 'let x j = Yojson.Safe.Util.member "a" j\n' >"$tmp/repo/cli/test/test_x.ml"
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
expect pass "Sol_cli_json in the library, Util in a test"

mkrepo; printf 'let n j = Yojson.Safe.Util.(member "items" j |> to_list)\n' >"$tmp/repo/cli/lib/deploy/b.ml"; commit
expect fail "a raising Util accessor in a library"

mkrepo; printf 'module U = Yojson.Basic.Util\n' >"$tmp/repo/cli/bin/cmd_bad.ml"; commit
expect fail "a Util alias in a command"
