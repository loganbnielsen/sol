#!/usr/bin/env bash
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
