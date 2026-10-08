#!/usr/bin/env bash
# support-pin-drift.sh must report any declared package whose installed pin is not
# the declared commit, and stay quiet when they agree. It compares commits, not
# version strings, so a different commit under the same version still drifts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DRIFT="$ROOT/internal/tooling/scripts/support-pin-drift.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

refs="$tmp/support-refs.txt"
printf '# refs\nfoo-eio https://github.com/loganbnielsen/foo-eio.git %s\nbar-eio https://github.com/loganbnielsen/bar-eio.git %s\n' \
  "$A" "$B" >"$refs"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/opam" <<'OPAM'
#!/bin/sh
# Only `show <pkg> --field=pin` is needed; print the fake pin target, if any.
[ "$1" = "show" ] && [ "$3" = "--field=pin" ] || exit 1
while read -r name target; do
  if [ "$name" = "$2" ]; then printf '%s\n' "$target"; exit 0; fi
done <"$PIN_FILE"
exit 0
OPAM
chmod +x "$tmp/bin/opam"

pins() { printf '%s\n' "$@" >"$tmp/pins"; }

run() {
  local refs_path="${1:-$refs}"
  PATH="$tmp/bin:$PATH" PIN_FILE="$tmp/pins" bash "$DRIFT" "$refs_path"
}

fail() { echo "  [FAIL] $1" >&2; exit 1; }

pins "foo-eio git+https://github.com/loganbnielsen/foo-eio.git#$A" \
     "bar-eio git+https://github.com/loganbnielsen/bar-eio.git#$B"
if ! run >/dev/null 2>&1; then
  fail "declared pins were reported as drift"
fi
echo "  [OK]   declared pins match"

pins "foo-eio git+https://github.com/loganbnielsen/foo-eio.git#$B" \
     "bar-eio git+https://github.com/loganbnielsen/bar-eio.git#$B"
if out="$(run 2>&1)"; then
  fail "a pin at another commit was accepted"
fi
grep -qF "foo-eio installed=$B declared=$A" <<<"$out" || fail "drift line for foo-eio missing: $out"
grep -qF "bar-eio" <<<"$out" && fail "an agreeing package was reported as drift: $out"
echo "  [OK]   a package pinned at another commit is reported"

pins "bar-eio git+https://github.com/loganbnielsen/bar-eio.git#$B"
if out="$(run 2>&1)"; then
  fail "an unpinned package was accepted"
fi
grep -qF "foo-eio installed=none declared=$A" <<<"$out" || fail "an unpinned package was not reported: $out"
echo "  [OK]   an unpinned package is reported"

# A different commit under the same package version still drifts: the comparison
# is the pin's commit, never its version string.
pins "foo-eio git+https://github.com/loganbnielsen/foo-eio.git#$B" \
     "bar-eio git+https://github.com/loganbnielsen/bar-eio.git#$B"
if out="$(run 2>&1)"; then
  fail "the same version at a different commit was accepted"
fi
grep -qF "foo-eio installed=$B declared=$A" <<<"$out" || fail "commit comparison missing: $out"
echo "  [OK]   comparison is by commit, not version"

if ! PATH=/nonexistent "$BASH" "$DRIFT" "$refs" >/dev/null 2>&1; then
  fail "a missing opam should not fail the caller"
fi
echo "  [OK]   opam absent is a no-op"

printf 'foo-eio https://github.com/loganbnielsen/foo-eio.git main\n' >"$refs"
code=0
run >/dev/null 2>&1 || code=$?
[ "$code" -eq 2 ] || fail "a malformed declaration should exit 2, got $code"
echo "  [OK]   a malformed declaration exits 2"

code=0
run "$tmp/absent.txt" >/dev/null 2>&1 || code=$?
[ "$code" -eq 2 ] || fail "a missing support-refs.txt should exit 2, got $code"
echo "  [OK]   a missing support-refs.txt exits 2"
