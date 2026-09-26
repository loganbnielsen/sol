#!/usr/bin/env bash
# BUG-059: move support packages to the current commit of their main branch, by
# rewriting support-refs.txt -- and, in lockstep, the framework packages'
# pin-depends that name the same package, which check_support_refs.sh requires
# to agree. The result is a diff to review and commit; nothing consumes a branch
# directly.
#
# Usage: bump-support-refs.sh [package...]   (no packages: bump all of them)
#        SUPPORT_ROOT=<dir> overrides the repository root (tests).
set -uo pipefail

root="${SUPPORT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
file="$root/support-refs.txt"
want=" $* "
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
changed=0

while IFS= read -r line; do
  read -r pkg url commit _ <<<"$line"
  case "$pkg" in '' | '#'*) printf '%s\n' "$line" >>"$tmp"; continue ;; esac
  if [ $# -gt 0 ] && [[ "$want" != *" $pkg "* ]]; then
    printf '%s\n' "$line" >>"$tmp"
    continue
  fi
  sha="$(git ls-remote "$url" refs/heads/main 2>/dev/null | awk 'NR == 1 { print $1 }')"
  if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "bump-support-refs: cannot resolve main of $pkg ($url)" >&2
    exit 1
  fi
  if [ "$sha" != "$commit" ]; then
    echo "$pkg: $commit -> $sha"
    changed=1
    while IFS= read -r opam; do
      sed -i "s|/${pkg}\.git#${commit}\"|/${pkg}.git#${sha}\"|g" "$root/$opam"
    done < <(git -C "$root" ls-files -- '*.opam')
  fi
  printf '%s %s %s\n' "$pkg" "$url" "$sha" >>"$tmp"
done <"$file"

cp "$tmp" "$file"
[ "$changed" -eq 1 ] || echo "bump-support-refs: already current"
