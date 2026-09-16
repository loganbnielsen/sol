#!/usr/bin/env bash
# Tests for classify-changes.sh.
#
# This classifier IS part of the CI gate: it decides whether the expensive
# suite runs. A future refactor that silently turned "skip expensive CI" into
# "skip CI for something important" would be invisible in a normal PR review,
# so its semantics are pinned here rather than left to inspection.
#
# Run: bash devtools/ci/test_classify_changes.sh
# Exits non-zero on the first failing expectation.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFY="$HERE/classify-changes.sh"

FAILURES=0
TOTAL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# check <expected> <path>...
check() {
  local expected="$1"; shift
  local list="$TMPDIR_TEST/list"
  : > "$list"
  local p
  for p in "$@"; do printf '%s\n' "$p" >> "$list"; done
  local got
  got="$("$CLASSIFY" --files-from "$list")"
  TOTAL=$((TOTAL + 1))
  if [ "$got" = "$expected" ]; then
    printf '  [OK]   %-9s %s\n' "$expected" "${*:-<empty>}"
  else
    printf '  [FAIL] expected %s, got %s: %s\n' "$expected" "$got" "${*:-<empty>}"
    FAILURES=$((FAILURES + 1))
  fi
}

# expect_failure_of <label> <expected-token> -- command...
# Used for the range plumbing, where the point is that a broken input still
# produces a decision rather than an error or an empty answer.
check_range() {
  local expected="$1" range="$2" label="$3"
  local got
  got="$("$CLASSIFY" --range "$range")"
  TOTAL=$((TOTAL + 1))
  if [ "$got" = "$expected" ]; then
    printf '  [OK]   %-9s %s\n' "$expected" "$label"
  else
    printf '  [FAIL] expected %s, got %s: %s\n' "$expected" "$got" "$label"
    FAILURES=$((FAILURES + 1))
  fi
}

echo "classify-changes: allowlist boundaries"
check docs-only README.md
check docs-only docs/foo.md
check docs-only docs/architecture/deep/nested.md
check docs-only pipeline/tickets/DONE/FEAT-036.md
check docs-only pipeline/tickets/READY_FOR_ENGINEERING/DEC-025.md
check docs-only devtools/perf/perf_baseline.json
check docs-only README.md docs/foo.md
check docs-only docs/foo.md pipeline/tickets/X.md devtools/perf/perf_baseline.json

echo
echo "classify-changes: .github/** is source-like regardless of extension"
check source .github/README.md
check source .github/workflows/ci.yml
check source .github/actions/pin-opam-packages/action.yml
check source .github/CODEOWNERS
check source .github/PULL_REQUEST_TEMPLATE.md
check source README.md .github/README.md

echo
echo "classify-changes: everything else is source"
check source framework/foo.ml
check source dune-project
check source sol.opam
check source Dockerfile
check source package.json
check source examples/pluto/pluto.opam
check source cli/sol/lib/sol_cli.ml
check source helm/values.yaml
check source terraform/main.tf
check source unknown/path
check source scripts/thing.sh

echo
echo "classify-changes: mixed diffs are source"
check source README.md framework/foo.ml
check source pipeline/tickets/X.md package.json
check source docs/foo.md .github/workflows/ci.yml
check source devtools/perf/perf_baseline.json cli/sol/bin/main.ml

echo
echo "classify-changes: empty and unresolvable input fails closed"
check source
check source ""
check_range source "no-such-ref...also-missing" "unresolvable range"
check_range source "HEAD...nonexistent-ref" "half-unresolvable range"
check_range source "" "empty range argument"

echo
echo "classify-changes: range mode resolves a real range"
# A scratch repository, so this does not depend on the host repo's history.
SCRATCH="$TMPDIR_TEST/scratch"
mkdir -p "$SCRATCH"
(
  cd "$SCRATCH"
  git init -q .
  git config user.email test@example.com
  git config user.name test
  mkdir -p docs pipeline/tickets
  printf 'x\n' > README.md
  git add -A && git commit -qm base
  BASE="$(git rev-parse HEAD)"
  printf 'y\n' > docs/added.md
  git add -A && git commit -qm "docs only"
  echo "$BASE $(git rev-parse HEAD)" > "$TMPDIR_TEST/range-docs"
  BASE2="$(git rev-parse HEAD)"
  printf 'z\n' > framework_file.ml
  git add -A && git commit -qm "source"
  echo "$BASE2 $(git rev-parse HEAD)" > "$TMPDIR_TEST/range-source"
)
read -r D_BASE D_HEAD < "$TMPDIR_TEST/range-docs"
read -r S_BASE S_HEAD < "$TMPDIR_TEST/range-source"
( cd "$SCRATCH" && check_range docs-only "$D_BASE...$D_HEAD" "docs-only commit range" )
( cd "$SCRATCH" && check_range source    "$S_BASE...$S_HEAD" "source commit range" )
( cd "$SCRATCH" && check_range source    "$D_BASE...$S_HEAD" "range spanning docs then source" )

echo
echo "classify-changes: --staged mode"
(
  cd "$SCRATCH"
  printf 'w\n' > docs/staged.md
  git add docs/staged.md
  got="$("$CLASSIFY" --staged)"
  TOTAL=$((TOTAL + 1))
  if [ "$got" = "docs-only" ]; then
    printf '  [OK]   %-9s staged docs-only file\n' "$got"
  else
    printf '  [FAIL] expected docs-only, got %s: staged docs-only file\n' "$got"
    FAILURES=$((FAILURES + 1))
  fi
  printf 'v\n' > staged_source.ml
  git add staged_source.ml
  got="$("$CLASSIFY" --staged)"
  TOTAL=$((TOTAL + 1))
  if [ "$got" = "source" ]; then
    printf '  [OK]   %-9s staged docs + source file\n' "$got"
  else
    printf '  [FAIL] expected source, got %s: staged docs + source file\n' "$got"
    FAILURES=$((FAILURES + 1))
  fi
)

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "classify-changes: all $TOTAL expectations hold."
  exit 0
fi
echo "classify-changes: $FAILURES of $TOTAL expectations FAILED."
exit 1
