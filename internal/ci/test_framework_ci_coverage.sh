#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "  [FAIL] $1"
  exit 1
}

ok() {
  echo "  [OK]   $1"
}

STEP="Unit tests (no broker/Postgres/Loki required)"

fixture() {
  mkdir -p "$WORK/internal/ci" "$WORK/.github/workflows" "$WORK/framework/ocaml/alpha/test" "$WORK/framework/ocaml/beta/test"
  cp "$ROOT/internal/ci/check_framework_ci_coverage.py" "$WORK/internal/ci/"
  cat > "$WORK/framework/ocaml/alpha/test/dune" <<'DUNE'
(test
 (name test_alpha)
 (libraries windtrap))
DUNE
  cat > "$WORK/framework/ocaml/beta/test/dune" <<'DUNE'
(tests
 (names test_beta)
 (libraries windtrap))
DUNE
}

workflow() {
  cat > "$WORK/.github/workflows/ci.yml" <<YAML
name: CI
on:
  pull_request:
jobs:
  test:
    steps:
      - name: $STEP
        run: opam exec -- dune test $1 cli/test/
YAML
}

run_guard() {
  set +e
  OUT="$(python3 "$WORK/internal/ci/check_framework_ci_coverage.py" 2>&1)"
  RC=$?
  set -e
}

fixture

workflow "framework/ocaml/alpha/"
run_guard
[ "$RC" != 0 ] || fail "a package missing from the unit step was accepted"
case "$OUT" in
  *"framework/ocaml/beta"*) ;;
  *) fail "the failure did not name the missing package (got: $OUT)" ;;
esac
ok "a unit suite outside the CI unit step fails the guard, and is named"

workflow "framework/ocaml/alpha/ framework/ocaml/beta/"
run_guard
[ "$RC" = 0 ] || fail "a fully covered framework tree was rejected: $OUT"
ok "every unit suite in the step passes (the mutation above is not vacuous)"

cat > "$WORK/framework/ocaml/beta/test/dune" <<'DUNE'
(executable
 (name test_beta)
 (libraries windtrap))

(rule
 (alias runtest-integration)
 (action
  (run ./test_beta.exe)))
DUNE
workflow "framework/ocaml/alpha/"
run_guard
[ "$RC" != 0 ] || fail "an integration alias no step builds was accepted: $OUT"
case "$OUT" in
  *"framework/ocaml/beta"*) ;;
  *) fail "the failure did not name the unbuilt alias (got: $OUT)" ;;
esac
ok "a runtest-integration alias outside every CI step fails the guard, and is named"

workflow "framework/ocaml/alpha/ @framework/ocaml/beta/test/runtest-integration"
run_guard
[ "$RC" = 0 ] || fail "a package whose suite needs infrastructure was still required: $OUT"
ok "a package with no unit suite (integration-only) is not required once its alias is built"

rm -rf "$WORK/framework/ocaml/beta"
workflow "framework/ocaml/alpha/"
run_guard
[ "$RC" = 0 ] || fail "a framework tree without the second package was rejected: $OUT"
ok "the guard accepts the tree it was built from"

echo "framework CI coverage guard: all expectations hold."
