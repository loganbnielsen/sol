#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$root/internal/ci/check_gcloud_interface.sh"

fail() {
  echo "  [FAIL] $1" >&2
  exit 1
}

without_gcloud=(env PATH=/usr/bin:/bin)

if "${without_gcloud[@]}" "$guard" >/dev/null 2>&1; then
  fail "the guard passed without gcloud and without an opt-out"
fi
echo "  [OK]   a missing gcloud fails the guard"

if ! "${without_gcloud[@]}" CHECK_GCLOUD_INTERFACE_ALLOW_MISSING_GCLOUD=1 "$guard" >/dev/null 2>&1; then
  fail "the explicit opt-out did not let the guard pass"
fi
echo "  [OK]   the named opt-out runs the static checks and skips only the interface check"

echo "gcloud interface guard: all expectations hold."
