#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$root/internal/ci/check_gcloud_interface.sh"

fail() {
  echo "  [FAIL] $1" >&2
  exit 1
}

bin="$(mktemp -d)"
trap 'rm -rf "$bin"' EXIT
for tool in bash git grep sed; do
  resolved="$(command -v "$tool" || true)"
  [ -n "$resolved" ] || fail "the fixture needs $tool on PATH"
  ln -s "$resolved" "$bin/$tool"
done

if env PATH="$bin" "$guard" >/dev/null 2>&1; then
  fail "the guard passed without gcloud and without an opt-out"
fi
echo "  [OK]   a missing gcloud fails the guard"

if ! env PATH="$bin" CHECK_GCLOUD_INTERFACE_ALLOW_MISSING_GCLOUD=1 "$guard" >/dev/null 2>&1; then
  fail "the explicit opt-out did not let the guard pass"
fi
echo "  [OK]   the named opt-out runs the static checks and skips only the interface check"

echo "gcloud interface guard: all expectations hold."
