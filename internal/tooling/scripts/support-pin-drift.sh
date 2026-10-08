#!/usr/bin/env bash
# Report support packages whose installed opam pin is not the commit declared in
# support-refs.txt. Compares commit SHAs, never version strings, so a re-tagged
# release cannot masquerade as the declared revision.
#
# Exit 0: every declared package is pinned at its declared commit, or opam is
#         unavailable so there is no installed pin to compare.
# Exit 1: one or more declared packages are missing or pinned at another commit.
#         Each drifted package is printed to stdout as
#           <package> installed=<sha|none> declared=<sha>
# Exit 2: support-refs.txt is missing or malformed, so nothing can be compared.
set -uo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
root="$(cd "$script_dir/../../.." && pwd)"
refs="${1:-$root/support-refs.txt}"

[ -f "$refs" ] || { echo "support-pin-drift: $refs not found" >&2; exit 2; }

if ! command -v opam >/dev/null 2>&1; then
  echo "support-pin-drift: opam is not on PATH; no installed pins to compare" >&2
  exit 0
fi

pkgs=()
wants=()
while read -r pkg url commit extra; do
  case "$pkg" in '' | '#'*) continue ;; esac
  if [ -n "${extra:-}" ] || [ -z "${url:-}" ] || ! [[ "${commit:-}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "support-pin-drift: $refs: '$pkg ${url:-} ${commit:-}' is not '<package> <url> <40-hex commit>'" >&2
    exit 2
  fi
  pkgs+=("$pkg")
  wants+=("$commit")
done <"$refs"

[ "${#pkgs[@]}" -gt 0 ] || { echo "support-pin-drift: $refs declares no packages" >&2; exit 2; }

drift=0
index=0
while [ "$index" -lt "${#pkgs[@]}" ]; do
  pkg="${pkgs[$index]}"
  want="${wants[$index]}"
  target="$(opam show "$pkg" --field=pin 2>/dev/null)"
  installed="${target##*#}"
  if [[ ! "$installed" =~ ^[0-9a-f]{40}$ ]] || [ "$installed" != "$want" ]; then
    printf '%s installed=%s declared=%s\n' "$pkg" "${installed:-none}" "$want"
    drift=1
  fi
  index=$((index + 1))
done

exit "$drift"
