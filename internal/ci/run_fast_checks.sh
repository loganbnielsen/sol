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
failed=0

echo "fast checks: build"
if ! dune build; then
  failed=1
fi

echo "fast checks: formatting"
if ! bash internal/ci/check_ocamlformat.sh --all; then
  failed=1
fi

echo "fast checks: repository invariants"
if ! bash internal/tooling/scripts/verify.sh always; then
  failed=1
fi
if ! bash internal/tooling/scripts/verify.sh static; then
  failed=1
fi

echo ""
echo "fast checks: finished in $((SECONDS - started))s"
exit "$failed"
