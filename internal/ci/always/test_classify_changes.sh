#!/usr/bin/env bash

set -uo pipefail
CI="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$CI/lib/scratch_repo.sh"

CLASSIFY="$CI/classify-changes.sh"

FAILURES=0
TOTAL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

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
check docs-only README.md docs/foo.md

echo
echo "classify-changes: a verification input does not ride the docs-only path"
check source internal/tooling/perf/perf_baseline.json
check source internal/tooling/perf/perf_baseline.json cli/bin/main.ml

echo
echo "classify-changes: generated documents are source-like, the prose beside them is not"
check source docs/reference/cli.md
check docs-only docs/reference/runtime.md
check docs-only docs/reference/README.md
check source docs/reference/cli.md docs/foo.md

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
check source cli/lib/sol_cli.ml
check source helm/values.yaml
check source terraform/main.tf
check source unknown/path
check source scripts/thing.sh

echo
echo "classify-changes: a listed language tree classifies by language"
check ocaml framework/ocaml/foo.ml
check ocaml examples/pluto/app/checkout/checkout_svc/main.ml
check ocaml examples/pluto/app/comms/notify_worker/main.ml
check ocaml examples/pluto/app/payments/charge_svc/main.ml
check ocaml examples/pluto/contract/contract.ml
check ocaml examples/pluto/lib/notification.ml
check ocaml internal/fixtures/venus/app/comms/notify_worker/Dockerfile
check ocaml internal/fixtures/local-demo/bin/demo.ml
check typescript framework/typescript/foo.ts
check typescript examples/pluto/app/demo_ts/order_svc/src/index.ts
check typescript examples/pluto/app/demo_ts/fulfillment_worker/sol.toml
check typescript platform/shared/templates/svc-ts/src/index.ts
check typescript platform/shared/templates/worker-ts/Dockerfile

echo
echo "classify-changes: a shared or unlisted path beside a language tree is source"
check source examples/pluto/sol.yml
check source examples/pluto/sol/environments.yml
check source examples/pluto/db/migrations/0005_orders.sql
check source examples/pluto/events/comms/sol.toml
check source platform/shared/templates/svc/Dockerfile
check source platform/shared/templates/workspace/app/comms/notify_worker/Dockerfile
check source internal/ci/classify-changes.sh
check source internal/ci/README.md
check source cli/lib/sol_cli.ml

echo
echo "classify-changes: a mixed-language diff is source"
check source framework/ocaml/foo.ml examples/pluto/app/demo_ts/order_svc/src/index.ts
check source examples/pluto/app/checkout/checkout_svc/main.ml examples/pluto/app/demo_ts/order_svc/src/index.ts
check source framework/ocaml/foo.ml cli/lib/sol_cli.ml
check typescript examples/pluto/app/demo_ts/order_svc/src/index.ts docs/foo.md

echo
echo "classify-changes: mixed diffs are source"
check source README.md framework/foo.ml
check source docs/foo.md .github/workflows/ci.yml
check source internal/tooling/perf/perf_baseline.json cli/bin/main.ml

echo
echo "classify-changes: empty and unresolvable input fails closed"
check source
check source ""
check_range source "no-such-ref...also-missing" "unresolvable range"
check_range source "HEAD...nonexistent-ref" "half-unresolvable range"
check_range source "" "empty range argument"

echo
echo "classify-changes: range mode resolves a real range"
SCRATCH="$TMPDIR_TEST/scratch"
mkdir -p "$SCRATCH"
(
  cd "$SCRATCH"
  scratch_repo_init .
  git config user.email test@example.com
  git config user.name test
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
