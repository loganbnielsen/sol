#!/usr/bin/env bash
set -uo pipefail

refs="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/support-refs.txt}"
[ -f "$refs" ] || { echo "pin-support-packages: $refs not found" >&2; exit 1; }

retry_pin() {
  local pkg="$1" source="$2" attempt=1 delay=5 log host
  log="$(mktemp)"
  while true; do
    if opam pin add "$pkg" "$source" -y 2>&1 | tee "$log"; then
      rm -f "$log"
      return 0
    fi
    if [ "$attempt" -ge 3 ]; then
      host="$(grep -oE 'Fetch_fail\("[^"]+' "$log" | tail -1 | sed -E 's/.*"//; s|^https?://||; s|/.*||' || true)"
      echo "::error::opam pin ${pkg} failed after 3 attempts${host:+ — unreachable host: ${host}}" >&2
      rm -f "$log"
      return 1
    fi
    echo "::warning::opam pin ${pkg} failed (attempt ${attempt}/3); retrying in ${delay}s" >&2
    attempt=$((attempt + 1))
    sleep "$delay"
    delay=$((delay * 2))
  done
}

while read -r -u 3 pkg url commit extra; do
  case "$pkg" in '' | '#'*) continue ;; esac
  if [ -n "${extra:-}" ] || ! [[ "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo "pin-support-packages: $refs: '$pkg $url $commit${extra:+ $extra}' is not '<package> <url> <40-hex commit>'" >&2
    exit 1
  fi
  retry_pin "$pkg" "${url}#${commit}" || exit 1
done 3<"$refs"
