#!/usr/bin/env bash
# Assertions for qualification harnesses (HARDEN-003).
#
# The rule these exist to enforce:
#
#   A qualification assertion must be demonstrated capable of failing when its
#   claimed condition is violated.
#
# The failure they prevent is specific and quiet. An assertion that greps a path
# the run never wrote cannot pass *or* fail on the thing it claims to test, so it
# looks like coverage in a green run. That happened here: an assertion grepped
# LIFECYCLE_LOG for text the CLI writes to stdout, while the log file holds only
# the fake tools' invocations. Switching to these helpers makes a missing or empty
# target a loud failure rather than a silent pass.
#
# Sourced, not executed. See test_qualification_assertions.sh for the mutation test
# that demonstrates each of them can fail.

# assert_contains <label> <file> <needle>
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

# assert_not_contains <label> <file> <needle>
#
# The missing-file guard matters more here than for assert_contains: a negative
# assertion reads a missing file as "the thing is absent", which is exactly the
# vacuous pass this file exists to prevent.
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
