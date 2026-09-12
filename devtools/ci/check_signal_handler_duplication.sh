#!/usr/bin/env bash
# Guardrail for REFAC-043/REFAC-081: the self-pipe signal handler has subtle
# correctness requirements (async-signal-safe write, cloexec, non-blocking
# write end) and once lived in three independent copies across sol-svc,
# sol-worker and sol-fn. REFAC-043 claimed the extraction but it never landed;
# REFAC-081 actually moved it to framework/sol-runtime. This fails if the shape
# creeps back into a primitive.
#
# Deliberately a grep over the markers unique to the self-pipe, not an
# OCaml/AST linter -- matching the "No elaborate lint tooling" rule the
# platform-component drift guardrail follows. KNOWN GAP: it catches the
# self-pipe specifically, not any future duplication of some other shared
# behaviour; the fix for that class is to add the new shared module to
# sol-runtime and a marker here.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
primitive_libs=(
  "$repo_root/framework/sol-svc/lib"
  "$repo_root/framework/sol-worker/lib"
  "$repo_root/framework/sol-fn/lib"
)

if hits="$(grep -REn 'Unix\.pipe|Unix\.set_nonblock|Sys\.set_signal' "${primitive_libs[@]}" 2>/dev/null)"; then
  echo "signal-handler duplication guardrail: the self-pipe handler belongs in" >&2
  echo "framework/sol-runtime (Sol_runtime.install_signal_handler), not a primitive:" >&2
  echo "$hits" >&2
  exit 1
fi

echo "signal-handler duplication guardrail: ok (one copy, in framework/sol-runtime)"
