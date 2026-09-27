#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
primitive_libs=(
  "$repo_root/framework/ocaml/sol-svc/lib"
  "$repo_root/framework/ocaml/sol-worker/lib"
  "$repo_root/framework/ocaml/sol-fn/lib"
)

if hits="$(grep -REn 'Unix\.pipe|Unix\.set_nonblock|Sys\.set_signal' "${primitive_libs[@]}" 2>/dev/null)"; then
  echo "signal-handler duplication guardrail: the self-pipe handler belongs in" >&2
  echo "framework/ocaml/sol-runtime (Sol_runtime.install_signal_handler), not a primitive:" >&2
  echo "$hits" >&2
  exit 1
fi

echo "signal-handler duplication guardrail: ok (one copy, in framework/ocaml/sol-runtime)"
