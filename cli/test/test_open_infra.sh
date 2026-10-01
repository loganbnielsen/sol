#!/usr/bin/env bash
set -euo pipefail

sol="$(realpath "${1:-}")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
check() {
  local what="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "test_open_infra: $what: expected [$expected], got [$actual]" >&2
    fail=1
  fi
}
check_contains() {
  local what="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *)
      echo "test_open_infra: $what: expected to find '$needle' in:" >&2
      echo "$haystack" >&2
      fail=1
      ;;
  esac
}

mkdir -p "$tmp/sol"
cat >"$tmp/sol/environments.yml" <<'EOF'
prod:
  targets:
    aws/us-east-1:
      kube_context: prod-us-east-1
EOF
touch "$tmp/sol.yml"

run() {
  set +e
  output="$(cd "$tmp" && "$sol" "$@" 2>&1)"
  rc=$?
  set -e
}

run open infra --target prod/aws/us-east-1 --links
check "a target-scoped infra view exits 0" 0 "$rc"
check_contains "it opens the target-infrastructure dashboard" "/d/sol-target-infrastructure" "$output"
check_contains "and prints the target's provider console" "console.aws.amazon.com" "$output"
check_contains "naming this target's region" "region=us-east-1" "$output"

run open infra --links
check "the infra view without a target is refused" 1 "$rc"
check_contains "naming the flag it needs" "--target" "$output"

run open infra payments --target prod/aws/us-east-1 --links
check "the infra view with a scope is refused" 1 "$rc"
check_contains "naming it target-scoped" "takes no application scope" "$output"

run open infra nope --target prod/aws/us-east-1 --links
check "any scope is refused, not only a resolvable one" 1 "$rc"

exit "$fail"
