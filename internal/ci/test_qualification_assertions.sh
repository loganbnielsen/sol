#!/usr/bin/env bash

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
helpers="$root/internal/ci/qualification_assertions.sh"

# shellcheck source=qualification_assertions.sh
. "$helpers"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

present="$tmp/present"
printf 'expected line\n' >"$present"
empty="$tmp/empty"
: >"$empty"
missing="$tmp/never-written"

fail=0
expect_fail() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "test_qualification_assertions: $description was ACCEPTED, so this assertion cannot fail." >&2
    fail=1
  fi
}

expect_pass() {
  local description="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    echo "test_qualification_assertions: $description was REJECTED." >&2
    fail=1
  fi
}

expect_pass "a present needle" assert_contains "present" "$present" "expected line"
expect_fail "a needle that is absent" assert_contains "absent" "$present" "not there"
expect_fail "a target that was never written" assert_contains "missing" "$missing" "anything"
expect_fail "an empty target" assert_contains "empty" "$empty" ""

expect_fail "a present needle under a negative assertion" assert_not_contains "present" "$present" "expected line"
expect_pass "a needle that is absent" assert_not_contains "absent" "$present" "not there"
expect_fail "a target that was never written" assert_not_contains "missing" "$missing" "anything"
expect_fail "an empty target" assert_not_contains "empty" "$empty" "anything"

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "test_qualification_assertions: both helpers reject a missing or empty target, and each fails on the condition it is meant to catch."
