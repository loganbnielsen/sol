#!/usr/bin/env bash
set -uo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
refs="$root/support-refs.txt"
fail=0
err() { echo "check_support_refs: $*" >&2; fail=1; }

[ -f "$refs" ] || { err "support-refs.txt is missing"; exit 1; }

declare -A commit_of
while read -r pkg url commit extra; do
  case "$pkg" in '' | '#'*) continue ;; esac
  if [ -n "${extra:-}" ] || [ -z "${url:-}" ] || ! [[ "${commit:-}" =~ ^[0-9a-f]{40}$ ]]; then
    err "support-refs.txt: '$pkg ${url:-} ${commit:-}' is not '<package> <git url> <40-hex commit>'"
    continue
  fi
  [ -n "${commit_of[$pkg]:-}" ] && err "support-refs.txt: $pkg is declared twice"
  commit_of[$pkg]="$commit"
done <"$refs"
[ "${#commit_of[@]}" -gt 0 ] || err "support-refs.txt declares no packages"

names="$(printf '%s|' "${!commit_of[@]}")"
names="${names%|}"

files="$(git -C "$root" ls-files |
  grep -vE '^(support-refs\.txt|internal/ci/pin-support-packages\.sh|internal/tooling/scripts/bump-support-refs\.sh|internal/ci/(check|test)_support_refs\.sh)$' |
  grep -vE '^internal/(pipeline/(tickets|audits|dogfood/2)|qualification/records|planning/)' || true)"

while IFS= read -r f; do
  [ -f "$root/$f" ] || continue
  hits="$(grep -nE "loganbnielsen/(${names}|\\\$[A-Za-z_{][A-Za-z_}]*)\.git([^#0-9A-Za-z_-]|$|#(\$|[^0-9a-f]|[0-9a-f]{0,39}([^0-9a-f]|$)))" "$root/$f" || true)"
  [ -n "$hits" ] && while IFS= read -r h; do err "$f:$h -- support repository without an exact commit"; done <<<"$hits"
  hits="$(grep -nE "opam pin add( -y)? +\"?(${names})\b" "$root/$f" || true)"
  [ -n "$hits" ] && while IFS= read -r h; do err "$f:$h -- pin support packages with internal/ci/pin-support-packages.sh"; done <<<"$hits"
  hits="$(grep -nE 'ls-remote.*refs/heads/main' "$root/$f" || true)"
  [ -n "$hits" ] && while IFS= read -r h; do err "$f:$h -- resolves a branch; support revisions come from support-refs.txt"; done <<<"$hits"
done <<<"$files"

while IFS= read -r opam; do
  while read -r pkg sha; do
    want="${commit_of[$pkg]:-}"
    if [ -z "$want" ]; then
      err "$opam: pin-depends names $pkg, which support-refs.txt does not declare"
    elif [ "$sha" != "$want" ]; then
      err "$opam: pin-depends has $pkg at $sha, support-refs.txt at $want"
    fi
  done < <(grep -oE '"[a-z0-9-]+\.[^"]*" +"git\+https://github\.com/loganbnielsen/[a-z0-9-]+\.git#[0-9a-f]{40}"' "$root/$opam" |
    sed -E 's|^"([a-z0-9-]+)\.[^"]*" +"git\+https://github\.com/loganbnielsen/[a-z0-9-]+\.git#([0-9a-f]{40})"$|\1 \2|')
done < <(git -C "$root" ls-files -- '*.opam')

if [ "$fail" -ne 0 ]; then
  echo "check_support_refs: support-library revisions must come from support-refs.txt (BUG-059)" >&2
  exit 1
fi
echo "check_support_refs: ${#commit_of[@]} support package(s) declared; every consumer uses the declared commits"
