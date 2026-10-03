#!/usr/bin/env bash
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GUARD="$ROOT/internal/ci/check_contract_bindings.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$scratch/examples" "$scratch/platform/shared/templates"
cp -R "$ROOT/examples/pluto" "$scratch/examples/pluto"
cp -R "$ROOT/platform/shared/templates/workspace" "$scratch/platform/shared/templates/workspace"

if ! CONTRACT_BINDINGS_CHECKOUT="$scratch" bash "$GUARD" >/dev/null 2>&1; then
  echo "the guard must pass on an unmodified checkout"
  exit 1
fi

printf '\n' >>"$scratch/examples/pluto/events/payments/payments_contract.ml"
if output="$(CONTRACT_BINDINGS_CHECKOUT="$scratch" bash "$GUARD" 2>&1)"; then
  echo "the guard must fail when a checked-in binding drifts"
  exit 1
fi
case "$output" in
  *payments_contract.ml*) ;;
  *)
    echo "the failure must name the drifted file, got: $output"
    exit 1
    ;;
esac

cp "$ROOT/examples/pluto/events/payments/payments_contract.ml" \
  "$scratch/examples/pluto/events/payments/payments_contract.ml"
rm "$scratch/platform/shared/templates/workspace/events/payments/payments_contract.ml"
if CONTRACT_BINDINGS_CHECKOUT="$scratch" bash "$GUARD" >/dev/null 2>&1; then
  echo "the guard must fail when a checked-in binding is missing"
  exit 1
fi
