#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_no_comments.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run() {
  local want="$1" name="$2" content="$3"
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/lib"
  git -C "$tmp/repo" init -q
  printf '%s\n' "$content" >"$tmp/repo/lib/a.ml"
  git -C "$tmp/repo" add -A
  if "$CHECK" "$tmp/repo" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" != "$want" ]; then
    echo "  [FAIL] $name (expected $want, got $got)"
    exit 1
  fi
  echo "  [OK]   $name"
}

run pass "plain code" 'let x = 1'
run pass "a comment opener inside a string" 'let s = "(* not a comment *)"'
run pass "a comment opener inside a quoted string" 'let s = {|(* not a comment *)|}'
run pass "the multiplication operator" 'let f = ( * ) 2'
run pass "an escaped quote in a string" 'let s = "a \" (* b"'
run fail "a comment" 'let x = 1 (* one *)'
run fail "a doc comment" '(** the answer *)
let x = 42'
run fail "a comment after a character literal" "let q = '\"' (* quote *)"
run fail "a comment after a type variable" "type 'a t = 'a list (* list *)"
