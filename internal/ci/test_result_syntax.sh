#!/usr/bin/env bash
# Mutation test for check_result_syntax.sh (REFAC-137).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_result_syntax.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkrepo() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/cli/lib" "$tmp/repo/framework/ocaml/x/lib" "$tmp/repo/examples/app"
  git -C "$tmp/repo" init -q
  printf 'open Result.Syntax\nlet f x = let* y = x in Ok y\n' >"$tmp/repo/cli/lib/a.ml"
  printf 'let g x =\n  let open Result.Syntax in\n  let* y = x in\n  Ok y\n' \
    >"$tmp/repo/framework/ocaml/x/lib/b.ml"
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
expect pass "Result.Syntax, top-level and local"

mkrepo; printf 'let ( let* ) = Result.bind\n' >"$tmp/repo/framework/ocaml/x/lib/c.ml"; commit
expect fail "a hand-written let* in the framework"

mkrepo; printf 'let f x =\n  let ( let* ) = Result.bind in\n  x\n' >"$tmp/repo/examples/app/d.ml"; commit
expect fail "a local hand-written let* in an example"
