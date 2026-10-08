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

pin_command="bash internal/ci/pin-support-packages.sh"
pin_drift="internal/tooling/scripts/support-pin-drift.sh"

echo "fast checks: support package pins"
build_pins_ok=1
if drift="$(bash "$pin_drift")"; then
  :
else
  pin_code=$?
  if [ "$pin_code" -eq 1 ]; then
    printf 'fast checks: support packages are not pinned to support-refs.txt:\n%s\n' "$drift" >&2
    if [ "${SOL_SKIP_SUPPORT_PIN:-0}" = "1" ]; then
      echo "fast checks: SOL_SKIP_SUPPORT_PIN=1; not building against the wrong pins" >&2
      echo "fast checks: re-pin and retry with: $pin_command" >&2
      build_pins_ok=0
    else
      echo "fast checks: re-pinning support packages: $pin_command" >&2
      if bash internal/ci/pin-support-packages.sh && drift="$(bash "$pin_drift")"; then
        echo "fast checks: support packages re-pinned to support-refs.txt"
      else
        printf 'fast checks: re-pin did not reach support-refs.txt:\n%s\n' "$drift" >&2
        echo "fast checks: re-pin and retry with: $pin_command" >&2
        build_pins_ok=0
      fi
    fi
  else
    printf 'fast checks: cannot compare support pins (%s): %s\n' "$pin_code" "$drift" >&2
  fi
fi

echo "fast checks: build"
if [ "$build_pins_ok" -eq 1 ]; then
  if ! dune build; then
    failed=1
  fi
else
  echo "fast checks: build skipped: support packages are not pinned to support-refs.txt" >&2
  failed=1
fi

echo "fast checks: formatting"
if ! bash internal/ci/check_ocamlformat.sh --all; then
  failed=1
fi

echo "fast checks: source invariants"
if ! bash internal/tooling/scripts/verify.sh static; then
  failed=1
fi

echo ""
echo "fast checks: finished in $((SECONDS - started))s"
exit "$failed"
