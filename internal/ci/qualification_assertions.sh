#!/usr/bin/env bash

assert_contains() {
  local label="$1" file="$2" needle="$3"
  if [ ! -s "$file" ]; then
    printf 'assert_contains: %s: %s is missing or empty, so this assertion cannot fail\n' \
      "$label" "$file" >&2
    return 1
  fi
  if ! grep -F -- "$needle" "$file" >/dev/null; then
    printf 'assert_contains: %s: expected to find %s in %s\n' "$label" "$needle" "$file" >&2
    sed 's/^/    | /' "$file" >&2
    return 1
  fi
}

assert_not_contains() {
  local label="$1" file="$2" needle="$3"
  if [ ! -s "$file" ]; then
    printf 'assert_not_contains: %s: %s is missing or empty, so this assertion cannot fail\n' \
      "$label" "$file" >&2
    return 1
  fi
  if grep -F -- "$needle" "$file" >/dev/null; then
    printf 'assert_not_contains: %s: did not expect to find %s in %s\n' "$label" "$needle" "$file" >&2
    sed 's/^/    | /' "$file" >&2
    return 1
  fi
}
