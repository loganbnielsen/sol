#!/usr/bin/env bash
# Mutation test for check_single_runner.sh (REFAC-134).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_single_runner.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkrepo() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/cli/lib/base" "$tmp/repo/cli/lib/cloud" "$tmp/repo/cli/bin" "$tmp/repo/cli/test"
  git -C "$tmp/repo" init -q
  printf 'let run p = Unix.create_process_env p [||] [||] Unix.stdin Unix.stdout Unix.stderr\n' \
    >"$tmp/repo/cli/lib/base/sol_cli_process.ml"
  printf 'let rm p = Unix.unlink p\n' >"$tmp/repo/cli/lib/base/sol_cli_fs.ml"
  printf 'let tf p = Unix.create_process p [||] Unix.stdin Unix.stdout Unix.stderr\n' \
    >"$tmp/repo/cli/lib/cloud/sol_cli_supervised.ml"
  printf 'let ok = Sol_cli_process.run (Sol_cli_process.cmd [ "true" ])\n' >"$tmp/repo/cli/bin/cmd_ok.ml"
  # Tests may remove their own files.
  printf 'let () = Sys.remove "x"\n' >"$tmp/repo/cli/test/test_x.ml"
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
expect pass "the runner, the supervisor and the fs helper own their calls"

mkrepo; printf 'let () = ignore (Sys.command "rm -rf x")\n' >"$tmp/repo/cli/lib/cloud/bad.ml"; commit
expect fail "Sys.command in a library"

mkrepo; printf 'let () = ignore (Unix.open_process_in "ls")\n' >"$tmp/repo/cli/test/test_bad.ml"; commit
expect fail "a spawn in a test"

mkrepo; printf 'let f p = try Sys.remove p with _ -> ()\n' >"$tmp/repo/cli/bin/cmd_bad.ml"; commit
expect fail "a swallowed removal in a command"
