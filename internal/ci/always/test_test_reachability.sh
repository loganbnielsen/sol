#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
guard="$here/check_test_reachability.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

reset_tree() {
  rm -rf "$work/tree"
  mkdir -p "$work/tree"
}

check_case() {
  local name="$1" expected="$2" needle="$3"
  set +e
  output="$(python3 "$guard" "$work/tree" 2>&1)"
  status=$?
  set -e
  printf '%s\n' "$output" > "$work/out"
  if [ "$expected" = pass ] && [ "$status" -ne 0 ]; then
    echo "✗ $name: the guard refused a reachable layout" >&2
    cat "$work/out" >&2
    exit 1
  fi
  if [ "$expected" = fail ] && [ "$status" -eq 0 ]; then
    echo "✗ $name: the guard accepted an unreachable module" >&2
    exit 1
  fi
  if [ -n "$needle" ] && ! grep -q "$needle" "$work/out"; then
    echo "✗ $name: the failure does not name $needle" >&2
    cat "$work/out" >&2
    exit 1
  fi
  echo "  ✓ $name"
}

reset_tree
mkdir -p "$work/tree/plain"
printf 'let () = print_endline "orphan"\n' > "$work/tree/plain/test_orphan.ml"
check_case "a module in a directory with no stanza fails" fail test_orphan

reset_tree
mkdir -p "$work/tree/plain"
printf '(tests\n (names other_test))\n' > "$work/tree/plain/dune"
printf 'let () = ()\n' > "$work/tree/plain/other_test.ml"
printf 'let () = ()\n' > "$work/tree/plain/test_orphan.ml"
check_case "a module missing from the executable list fails" fail test_orphan

reset_tree
mkdir -p "$work/tree/inlined"
printf '(library\n (name inlined)\n (inline_tests))\n' > "$work/tree/inlined/dune"
printf 'let%%test "works" = ()\n' > "$work/tree/inlined/test_inlined.ml"
check_case "an (inline_tests) library passes" pass ""

reset_tree
mkdir -p "$work/tree/linked"
printf '(tests\n (names test_listed))\n' > "$work/tree/linked/dune"
printf 'let () = ()\n' > "$work/tree/linked/test_listed.ml"
check_case "a listed (tests (names ...)) module passes" pass ""

reset_tree
mkdir -p "$work/tree/linked"
printf '(executable\n (name print_probe))\n' > "$work/tree/linked/dune"
printf 'let () = ()\n' > "$work/tree/linked/print_probe.ml"
check_case "an (executable (name ...)) module passes" pass ""

reset_tree
mkdir -p "$work/tree/helpers"
printf '(library\n (name helpers))\n' > "$work/tree/helpers/dune"
printf 'let helper () = ()\n' > "$work/tree/helpers/helper.ml"
check_case "a helper library module passes" pass ""

reset_tree
mkdir -p "$work/tree/plain"
printf 'let () = print_endline "test"\n' > "$work/tree/plain/test_hidden.ml"
check_case "a test-bearing module in a plain directory fails" fail test_hidden

echo "test_test_reachability: every case behaved"
