#!/usr/bin/env bash
# Mutation test for check_platform_assets_owner.sh (REFAC-114).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_platform_assets_owner.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkrepo() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/cli/lib/base" "$tmp/repo/cli/bin" "$tmp/repo/cli/test"
  git -C "$tmp/repo" init -q
  # The owner may do all of it.
  printf 'let r = Sys.getenv_opt "SOL_HOME"\nlet e = Unix.readlink "/proc/self/exe"\nlet c = "platform/shared/components.json"\n' \
    >"$tmp/repo/cli/lib/base/sol_cli_platform_assets.ml"
  printf 'let dir = Sol_cli_platform_assets.components_json (Sol_cli_platform_assets.resolve_or_exit ())\n' \
    >"$tmp/repo/cli/bin/cmd_ok.ml"
  # Tests may probe the resolver's discovery.
  printf 'let _ = Sol_cli_platform_assets.is_checkout "x"\nlet () = Unix.putenv "SOL_HOME" ""\n' \
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
expect pass "only the owner locates assets; tests may probe it"

mkrepo; printf 'let h = Sys.getenv_opt "SOL_HOME"\n' >"$tmp/repo/cli/bin/cmd_bad.ml"; commit
expect fail "a command reading SOL_HOME itself"

mkrepo; mkdir -p "$tmp/repo/cli/lib/local"; printf 'let e = Unix.readlink "/proc/self/exe"\n' >"$tmp/repo/cli/lib/local/x.ml"; commit
expect fail "a library locating its own binary"

mkrepo; printf 'let p root = Filename.concat root "platform/cloud/aws/cluster"\n' >"$tmp/repo/cli/bin/cmd_bad.ml"; commit
expect fail "a hand-built path into platform/"

mkrepo; printf 'let f = Sol_cli_platform_assets.find_ancestor Sol_cli_platform_assets.is_checkout "."\n' >"$tmp/repo/cli/bin/cmd_bad.ml"; commit
expect fail "a command running the resolver's discovery itself"
