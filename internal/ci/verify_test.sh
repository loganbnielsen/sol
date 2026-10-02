#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="$root/internal/tooling/scripts/verify.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
ok() { printf '  [OK]   %s\n' "$1"; }
bad() {
  printf '  [FAIL] %s\n' "$1"
  failures=$((failures + 1))
}

run() {
  VERIFY_CI_DIR="$1" bash "$VERIFY" "$2" >"$tmp/out" 2>&1
}

echo "verify runner: an unknown class is refused"
if run "$root/internal/ci" bogus; then
  bad "an unknown class was accepted"
elif grep -q 'unknown verification class' "$tmp/out"; then
  ok "unknown class refused, and the output names it"
else
  bad "the refusal does not say the class is unknown"
fi

echo
echo "verify runner: an empty class is refused"
mkdir -p "$tmp/empty/always"
if run "$tmp/empty" always; then
  bad "an empty class was accepted"
elif grep -q 'has no members' "$tmp/out"; then
  ok "an empty class is refused"
else
  bad "the empty-class refusal is not specific"
fi

echo
echo "verify runner: a class directory that is absent is refused"
if run "$tmp/absent" static; then
  bad "a missing class directory was accepted"
elif grep -q 'no directory' "$tmp/out"; then
  ok "a missing class directory is refused"
else
  bad "the missing-directory refusal is not specific"
fi

fixture="$tmp/fixture"
mkdir -p "$fixture"
printf '#!/usr/bin/env bash\nexit 1\n' >"$fixture/check_fails.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/check_passes.sh"

echo
echo "verify runner: a failing member fails the class and is named"
if run "$fixture" static; then
  bad "a failing member did not fail the class"
else
  grep -q 'FAIL.*check_fails.sh' "$tmp/out" && ok "the failing member is named" || bad "the failing member is not named"
  grep -q 'PASS.*check_passes.sh' "$tmp/out" && ok "the passing member is reported too" || bad "the passing member is not reported"
fi

echo
echo "verify runner: a missing result is a failure that names its member"
VERIFY_CI_DIR="$fixture" source "$VERIFY"
results="$tmp/results"
mkdir -p "$results"
members=("$fixture/check_passes.sh" "$fixture/check_fails.sh")
class=fixture
printf '0 1\n' >"$results/0.status"
printf '0 1\n' >"$results/1.status"
if report "$results" >/dev/null 2>&1; then
  ok "an all-pass result set reports success"
else
  bad "an all-pass result set failed"
fi
printf '1 1\n' >"$results/1.status"
if report "$results" >/dev/null 2>&1; then
  bad "a non-zero result reported success"
else
  ok "a non-zero result fails the run"
fi
rm -f "$results/0.status"
if report "$results" >"$tmp/out" 2>&1; then
  bad "a missing result was treated as a pass"
elif grep -q 'no-result.*check_passes.sh' "$tmp/out"; then
  ok "a missing result fails and names its member"
else
  bad "the missing-result failure does not name its member"
fi

echo
echo "verify runner: the real classes are not empty"
discover "$root/internal/ci/always" && ok "the always class has members" || bad "the always class is empty"
discover "$root/internal/ci" && ok "the static class has members" || bad "the static class is empty"

echo
if [ "$failures" -eq 0 ]; then
  echo "verify runner: every expectation held."
  exit 0
fi
echo "verify runner: $failures expectation(s) FAILED."
exit 1
