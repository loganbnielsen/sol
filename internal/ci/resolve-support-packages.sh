#!/usr/bin/env bash
# Print "<package> <commit>" for every support package in packages.txt, at the
# commit its main branch points to now. CI runs this once per workflow and pins
# every job to the result, so one run tests one dependency snapshot. Any package
# that cannot be resolved fails the whole snapshot.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES="${1:-$HERE/../../.github/actions/pin-opam-packages/packages.txt}"

while read -r pkg url; do
  case "$pkg" in '' | '#'*) continue ;; esac
  sha="$(git ls-remote "$url" refs/heads/main 2>/dev/null | awk 'NR == 1 { print $1 }')"
  if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "::error::cannot resolve main of support package $pkg ($url)" >&2
    exit 1
  fi
  printf '%s %s\n' "$pkg" "$sha"
done < "$PACKAGES"
