#!/usr/bin/env bash
set -euo pipefail

sol="$(realpath "${1:-}")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
check() {
  local what="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "test_open_options: $what: expected [$expected], got [$actual]" >&2
    fail=1
  fi
}
check_contains() {
  local what="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *)
      echo "test_open_options: $what: expected to find '$needle' in:" >&2
      echo "$haystack" >&2
      fail=1
      ;;
  esac
}

mkdir -p "$tmp/ws/sol"
cat >"$tmp/ws/sol/environments.yml" <<'EOF'
prod:
  targets:
    aws/us-east-1:
      kube_context: prod-us-east-1
EOF
touch "$tmp/ws/sol.yml"

run() {
  set +e
  output="$(cd "$tmp/ws" && "$sol" "$@" 2>&1)"
  rc=$?
  set -e
}

run open dashboard --links
check "the scope-addressed view with no overrides" 0 "$rc"
check_contains "resolves the local Grafana URL" "http://localhost:3000/d/sol-workspace-overview" "$output"

run open dashboard --links --observability-backend local
check "the backend flag is accepted" 0 "$rc"

run open dashboard --links --base-domain example.test
check "the base-domain flag is accepted" 0 "$rc"

run open dashboard --links --grafana-base-url http://grafana.example.test:3000
check "the grafana-base-url flag is accepted" 0 "$rc"
check_contains "and overrides the resolved URL" "http://grafana.example.test:3000/d/sol-workspace-overview" "$output"

run open logs --links --observability-backend local
check "the logs view takes the same destination flags" 0 "$rc"

run open logs payments/charge_svc --links
check "the logs view takes a unit scope" 0 "$rc"
check_contains "and selects the unit's labels" "%7Bworkspace%3D%5C%22ws%5C%22" "$output"

run open traces --links --observability-backend local
check "the traces view takes the same destination flags" 0 "$rc"
check_contains "and builds a Tempo TraceQL query" "%22queryType%22%3A%22traceql%22" "$output"

run open traces payments/charge_svc --links
check "the traces view takes a unit scope" 0 "$rc"
check_contains "and scopes the query to the unit's service name" "resource.service" "$output"

run open traces resource/rds/postgres --links
check "the traces view has no managed-resource view" 1 "$rc"
check_contains "and says so" "no traces view" "$output"

run open dashboard --links --loki-base-url http://loki.example.test:3100
check "an unused Loki flag is refused" 124 "$rc"

run open dashboard --links --loki-username someone
check "an unused Loki username is refused" 124 "$rc"

run open dashboard --links --loki-password secret
check "an unused Loki password is refused" 124 "$rc"

run open infra --target prod/aws/us-east-1 --links --observability-backend local
check "the target-scoped view takes the same destination flags" 0 "$rc"

exit "$fail"
