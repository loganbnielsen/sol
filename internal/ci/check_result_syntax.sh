#!/usr/bin/env bash
# REFAC-120 / REFAC-137: OCaml 5.4's stdlib ships Result.Syntax, so `let*` over
# results is `open Result.Syntax` (or `let open Result.Syntax in`), never a
# hand-written `let ( let* ) = Result.bind`. The rule covers every OCaml file in
# the repository -- the CLI, the framework, the tooling, and what users copy:
# the examples, the fixtures and the scaffold templates `sol new` writes.
#
# Usage: check_result_syntax.sh [repo-root]
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

files="$(git -C "$root" ls-files -- '*.ml')"
if [ -z "$files" ]; then
  echo "check_result_syntax: no OCaml sources found" >&2
  exit 1
fi

fail=0
checked=0
while IFS= read -r f; do
  checked=$((checked + 1))
  if hits="$(grep -nE 'let \( let\* \) *= *Result\.bind' "$root/$f")"; then
    while IFS= read -r hit; do
      echo "check_result_syntax: $f:$hit" >&2
    done <<<"$hits"
    fail=1
  fi
done <<<"$files"

if [ "$fail" -ne 0 ]; then
  echo "check_result_syntax: use Result.Syntax instead of a hand-written let*" >&2
  exit 1
fi
echo "check_result_syntax: $checked OCaml file(s) checked; no hand-written let*"
