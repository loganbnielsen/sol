#!/usr/bin/env bash
# REFAC-114 / DEC-049: Sol_cli_platform_assets is the only code that decides
# where Sol's own assets come from. A command that finds Sol's source tree
# itself -- reading SOL_HOME, walking up from its own executable, or
# hand-building a path into the platform/ tree -- bypasses the resolution order
# (SOL_HOME > installed bundle > source checkout) and works only from a
# checkout.
#
# Flags, in CLI code outside cli/lib/base/sol_cli_platform_assets.{ml,mli}:
#   "SOL_HOME"              the environment variable, as a string literal
#   /proc/self/exe          locating the running binary
#   "platform/              a string literal into the platform/ tree
#   Sol_cli_platform_assets.is_checkout / .find_ancestor   the resolver's discovery
# Tests (cli/test/) exercise the resolver and are out of scope.
#
# Usage: check_platform_assets_owner.sh [repo-root]
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
owner='cli/lib/base/sol_cli_platform_assets'

files="$(git -C "$root" ls-files -- 'cli/bin/*.ml' 'cli/bin/*.mli' 'cli/lib/*.ml' 'cli/lib/*.mli' |
  grep -v "^$owner\.mli\?$" || true)"

if [ -z "$files" ]; then
  echo "check_platform_assets_owner: no CLI sources found under cli/" >&2
  exit 1
fi

pattern='"SOL_HOME"|/proc/self/exe|"platform/|Sol_cli_platform_assets\.(is_checkout|find_ancestor)'
fail=0
checked=0
while IFS= read -r f; do
  checked=$((checked + 1))
  if hits="$(grep -nE "$pattern" "$root/$f")"; then
    while IFS= read -r hit; do
      echo "check_platform_assets_owner: $f:$hit" >&2
    done <<<"$hits"
    fail=1
  fi
done <<<"$files"

if [ "$fail" -ne 0 ]; then
  echo "check_platform_assets_owner: locate Sol's assets through Sol_cli_platform_assets (DEC-049), not directly" >&2
  exit 1
fi
echo "check_platform_assets_owner: $checked CLI source file(s) checked; only $owner locates Sol's assets"
