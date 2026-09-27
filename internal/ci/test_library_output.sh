#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_library_output.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkrepo() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/cli/lib/base" "$tmp/repo/cli/lib/cloud" "$tmp/repo/cli/bin"
  git -C "$tmp/repo" init -q
  printf 'let f () = Sol_cli_report.app "  prepare: %%s" "x"\n' >"$tmp/repo/cli/lib/cloud/a.ml"
  printf 'let terminal s = output_string stdout s\n' >"$tmp/repo/cli/lib/base/sol_cli_report.ml"
  printf 'let exit_on m = Printf.eprintf "%%s" m\n' >"$tmp/repo/cli/lib/base/sol_cli_exit.ml"
  printf 'let () = Printf.printf "done\\n"\n' >"$tmp/repo/cli/bin/cmd_ok.ml"
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
expect pass "reports in the library; the edge and commands print"

mkrepo; printf 'let f () = Printf.printf "  prepare...\\n%%!"\n' >"$tmp/repo/cli/lib/cloud/b.ml"; commit
expect fail "Printf.printf in a library"

mkrepo; printf 'let f m = prerr_endline m\n' >"$tmp/repo/cli/lib/cloud/c.ml"; commit
expect fail "prerr_endline in a library"
