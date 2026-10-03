#!/usr/bin/env bash
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GUARD="$ROOT/internal/ci/check_contract_bindings.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$scratch/examples" "$scratch/platform/shared/templates"
cp -R "$ROOT/examples/pluto" "$scratch/examples/pluto"
cp -R "$ROOT/platform/shared/templates/workspace" "$scratch/platform/shared/templates/workspace"

pluto_ocaml="$scratch/examples/pluto/events/payments/payments_contract.ml"
pluto_ts="$scratch/examples/pluto/app/demo_ts/contract/src/demo_ts_contract.ts"
template_ocaml="$scratch/platform/shared/templates/workspace/events/payments/payments_contract.ml"

restore() {
  cp "$ROOT/examples/pluto/events/payments/payments_contract.ml" "$pluto_ocaml"
  cp "$ROOT/examples/pluto/app/demo_ts/contract/src/demo_ts_contract.ts" "$pluto_ts"
  cp "$ROOT/platform/shared/templates/workspace/events/payments/payments_contract.ml" "$template_ocaml"
}

if ! CONTRACT_BINDINGS_CHECKOUT="$scratch" bash "$GUARD" >/dev/null 2>&1; then
  echo "the guard must pass on an unmodified checkout"
  exit 1
fi

mutate_and_expect() {
  local label="$1" needle="$2"
  if output="$(CONTRACT_BINDINGS_CHECKOUT="$scratch" bash "$GUARD" 2>&1)"; then
    echo "the guard must fail when $label"
    exit 1
  fi
  case "$output" in
    *"$needle"*) ;;
    *)
      echo "the failure must name $needle, got: $output"
      exit 1
      ;;
  esac
}

printf '\n' >>"$pluto_ocaml"
mutate_and_expect "a checked-in OCaml binding drifts" "payments_contract.ml"
restore

printf '\n' >>"$pluto_ts"
mutate_and_expect "a checked-in TypeScript binding drifts" "demo_ts_contract.ts"
restore

rm "$template_ocaml"
mutate_and_expect "a checked-in OCaml binding is missing" "payments_contract.ml"
restore
