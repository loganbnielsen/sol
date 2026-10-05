#!/usr/bin/env bash
set -uo pipefail

root="${SUPPORT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
file="$root/support-refs.txt"
want=" $* "

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

staged="$work/support-refs.txt"
resolved="$work/resolved"
backups="$work/backups"
: >"$staged"
: >"$resolved"

fail() {
  echo "bump-support-refs: $1" >&2
  exit 1
}

seen=""
while IFS= read -r line; do
  read -r pkg url commit _ <<<"$line"
  case "$pkg" in '' | '#'*) printf '%s\n' "$line" >>"$staged"; continue ;; esac
  if [ $# -gt 0 ] && [[ "$want" != *" $pkg "* ]]; then
    printf '%s\n' "$line" >>"$staged"
    continue
  fi
  seen="$seen$pkg "
  sha="$(git ls-remote "$url" refs/heads/main 2>/dev/null | awk 'NR == 1 { print $1 }')"
  if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    fail "cannot resolve main of $pkg ($url); no file was written"
  fi
  printf '%s %s %s\n' "$pkg" "$commit" "$sha" >>"$resolved"
  printf '%s %s %s\n' "$pkg" "$url" "$sha" >>"$staged"
done <"$file"

for requested in "$@"; do
  if [[ " $seen " != *" $requested "* ]]; then
    fail "no support reference named '$requested' in $file; no file was written"
  fi
done

opam_files="$(git -C "$root" ls-files -- '*.opam')"

restore() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -f "$backups/$name" ] || continue
    cp -p "$backups/$name" "$root/$name"
  done <<<"$opam_files"
}

changed=0
while IFS=' ' read -r pkg commit sha; do
  [ -n "$pkg" ] || continue
  [ "$sha" != "$commit" ] || continue
  changed=1
  echo "$pkg: $commit -> $sha"
  while IFS= read -r opam; do
    [ -n "$opam" ] || continue
    grep -qF "/${pkg}.git#${commit}\"" "$root/$opam" || continue
    mkdir -p "$backups/$(dirname "$opam")"
    cp -p "$root/$opam" "$backups/$opam" || { restore; fail "cannot stage $opam"; }
    sed -i "s|/${pkg}\\.git#${commit}\"|/${pkg}.git#${sha}\"|g" "$root/$opam" \
      || { restore; fail "cannot update $opam; the original pins were restored"; }
  done <<<"$opam_files"
done <"$resolved"

if ! cp "$staged" "$file"; then
  restore
  fail "cannot write $file; the original pins were restored"
fi

[ "$changed" -eq 1 ] || echo "bump-support-refs: already current"
