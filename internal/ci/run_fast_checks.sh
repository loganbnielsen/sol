#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
source "$root/internal/ci/lib/scratch_repo.sh"
scratch_repo_sanitize

if command -v opam >/dev/null; then
  eval "$(opam env 2>/dev/null)"
fi

started=$SECONDS
echo "fast checks: building (the checks read built artifacts)"
if ! build_output="$(dune build 2>&1)"; then
  printf '%s\n' "$build_output"
  echo "fast checks: build failed; no checks run"
  exit 1
fi

unit_failed=0
echo "fast checks: unit tests (serial: they hold dune's build lock)"
if ! unit_output="$(dune build @ci-unit 2>&1)"; then
  unit_failed=1
  printf '%s\n' "$unit_output"
  echo "fast checks: unit tests failed; running the guards anyway"
fi

lifecycle_failed=0
echo "fast checks: offline cloud lifecycle (serial: it holds dune's build lock)"
if ! lifecycle_output="$(dune build @ci-lifecycle 2>&1)"; then
  lifecycle_failed=1
  printf '%s\n' "$lifecycle_output"
  echo "fast checks: lifecycle tests failed; running the guards anyway"
fi

guards_failed=0
echo "fast checks: verification classes"
if ! bash internal/tooling/scripts/verify.sh always; then
  guards_failed=1
fi
if ! bash internal/tooling/scripts/verify.sh static; then
  guards_failed=1
fi
if ! bash internal/ci/verify_test.sh; then
  guards_failed=1
fi

echo ""
if [ "$unit_failed" -ne 0 ]; then
  echo "fast checks: unit tests FAILED"
fi
if [ "$lifecycle_failed" -ne 0 ]; then
  echo "fast checks: lifecycle tests FAILED"
fi
if [ "$guards_failed" -ne 0 ]; then
  echo "fast checks: verification classes FAILED"
fi
echo "fast checks: finished in $((SECONDS - started))s"
[ "$unit_failed" -eq 0 ] && [ "$lifecycle_failed" -eq 0 ] && [ "$guards_failed" -eq 0 ]
