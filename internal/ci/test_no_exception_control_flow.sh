#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/scratch_repo.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_no_exception_control_flow.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkrepo() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/cli/lib/deploy" "$tmp/repo/cli/lib/base" "$tmp/repo/cli/bin" "$tmp/repo/cli/test"
  scratch_repo_init "$tmp/repo"
  printf 'let f x = match x with Ok v -> Ok v | Error e -> Error e\n' >"$tmp/repo/cli/lib/deploy/a.ml"
  printf 'let t s = invalid_arg "Sol_cli_time: x is not a representable time"\n' >"$tmp/repo/cli/lib/base/sol_cli_time.ml"
  printf 'let g f = try f () with Eio.Cancel.Cancelled _ as exn -> raise exn\n(* this can raise, and *)\n' \
    >"$tmp/repo/cli/bin/cmd_ok.ml"
  printf 'let () = failwith "test"\n' >"$tmp/repo/cli/test/test_x.ml"
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
expect pass "results, a named invariant, re-raised cancellation, prose"

mkrepo; printf 'let f = function Ok v -> v | Error msg -> failwith msg\n' >"$tmp/repo/cli/lib/deploy/b.ml"; commit
expect fail "failwith on an Error in a library"

mkrepo; printf 'exception Deploy_failed of string\nlet f m = raise (Deploy_failed m)\n' >"$tmp/repo/cli/bin/cmd_bad.ml"; commit
expect fail "a command raising its own exception"

mkrepo; printf 'let t s = invalid_arg "something else"\n' >"$tmp/repo/cli/lib/base/sol_cli_time.ml"; commit
expect fail "an allow-listed file with an unlisted raise"
