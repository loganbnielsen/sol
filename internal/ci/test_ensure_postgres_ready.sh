#!/usr/bin/env bash
set -euo pipefail

repo="${1:-$(git rev-parse --show-toplevel)}"
ensure="$repo/platform/local/scripts/ensure-postgres.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin" "$work/state"

cat >"$work/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
state="${SOL_POSTGRES_TEST_STATE:?}"
case "${1:-} ${2:-}" in
  "ps --format")
    [ -f "$state/running" ] && echo sol-postgres
    ;;
  "run -d")
    touch "$state/running"
    printf 'run -d %s\n' "$*" >>"$state/invocations"
    echo started-container-id
    ;;
  "port "*)
    if [ -f "$state/published" ]; then cat "$state/published"; else printf '127.0.0.1:%s\n[::1]:%s\n' "$3" "$3"; fi
    ;;
  "run --rm")
    attempts=0
    [ -f "$state/attempts" ] && attempts="$(cat "$state/attempts")"
    attempts=$((attempts + 1))
    printf '%s\n' "$attempts" >"$state/attempts"
    printf 'query %s\n' "$*" >>"$state/invocations"
    if [ -f "$state/not-a-database" ]; then
      echo 'psql: error: connection to server failed: server closed the connection unexpectedly' >&2
      exit 1
    fi
    if [ -f "$state/answers-after" ] && [ "$attempts" -lt "$(cat "$state/answers-after")" ]; then
      echo 'psql: error: the database system is starting up' >&2
      exit 1
    fi
    echo 1
    ;;
  "exec sol-postgres")
    printf 'exec %s\n' "$*" >>"$state/invocations"
    exit 0
    ;;
  "logs --tail")
    echo "docker-entrypoint: performing post-bootstrap initialization ... ok"
    echo "FATAL: the database system is starting up"
    ;;
  *) : ;;
esac
DOCKER

cat >"$work/bin/nc" <<'NC'
#!/usr/bin/env bash
state="${SOL_POSTGRES_TEST_STATE:?}"
printf 'nc %s\n' "$*" >>"$state/invocations"
[ -f "$state/running" ]
NC

chmod +x "$work/bin/docker" "$work/bin/nc"
export PATH="$work/bin:$PATH"
export SOL_POSTGRES_TEST_STATE="$work/state"
export POSTGRES_READY_TIMEOUT_S=1
export POSTGRES_READY_INTERVAL_S=0.2

failures=0
ok() { printf '  [OK]   %s\n' "$1"; }
bad() {
  printf '  [FAIL] %s\n' "$1"
  failures=$((failures + 1))
}

reset_state() {
  rm -rf "$work/state"
  mkdir -p "$work/state"
}

run_ensure() {
  if "$ensure" >"$work/out" 2>&1; then
    status=0
  else
    status=$?
  fi
}

expect_exit() {
  if [ "$status" = "$1" ]; then ok "$2"; else bad "$2 (observed exit $status)"; fi
}

expect_text() {
  if grep -qF "$1" "$work/out"; then ok "$2"; else bad "$2"; fi
}

expect_no_text() {
  if grep -qF "$1" "$work/out"; then bad "$2"; else ok "$2"; fi
}

expect_invocation() {
  if grep -qF -- "$1" "$work/state/invocations"; then ok "$2"; else bad "$2"; fi
}

echo "ensure-postgres: a database that answers a query through the published port is ready"
reset_state
touch "$work/state/running"
run_ensure
expect_exit 0 "an answering database is accepted"
expect_text "Postgres ready at localhost:5432" "the readiness message is reported"
expect_text "export POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sol_dev" "the consumer URL is reported"
expect_invocation "localhost:5432/sol_dev" "the gate asked the published address"
expect_invocation "--network host" "the gate reached the loopback publication from the host network"
expect_invocation "SELECT 1" "the gate asked a query, not a port"

echo
echo "ensure-postgres: a container that accepts connections but cannot answer is refused"
reset_state
touch "$work/state/running" "$work/state/not-a-database"
run_ensure
expect_exit 1 "a connection-accepting non-database fails readiness"
expect_no_text "Postgres ready at" "readiness is never reported"
expect_text "did not answer a query at postgresql://postgres:dev@localhost:5432/sol_dev" "the failure names what was expected"
expect_text "the database system is starting up" "the container's own log lines are reported"
expect_invocation "SELECT 1" "the failure came after asking the database"

echo
echo "ensure-postgres: starting the container is not the readiness claim"
reset_state
touch "$work/state/not-a-database"
run_ensure
expect_exit 1 "a started container that cannot answer fails readiness"
expect_invocation "run -d" "the container was started"
expect_invocation "127.0.0.1:5432:5432" "the started container binds the loopback address"
expect_no_text "Postgres ready at" "readiness is not claimed for having started it"

echo
echo "ensure-postgres: a database that becomes usable is waited for, then accepted"
reset_state
touch "$work/state/running"
echo 3 >"$work/state/answers-after"
run_ensure
expect_exit 0 "a slow start is not a false failure"
expect_text "Postgres ready at localhost:5432" "readiness is reported once the query answers"
if [ "$(cat "$work/state/attempts")" -ge 3 ]; then
  ok "the gate retried the query until it answered"
else
  bad "the gate did not retry the query"
fi

echo
echo "ensure-postgres: an existing container published beyond loopback is refused"
reset_state
touch "$work/state/running"
printf '0.0.0.0:5432\n' >"$work/state/published"
run_ensure
expect_exit 1 "a broadly published database is refused"
expect_no_text "Postgres ready at" "readiness is not claimed"
expect_text "not on 127.0.0.1" "the refusal names the binding"
expect_text "docker rm -f sol-postgres" "the refusal names the recreation"

echo
if [ "$failures" -eq 0 ]; then
  echo "ensure-postgres readiness: every expectation held."
  exit 0
fi
echo "ensure-postgres readiness: $failures expectation(s) FAILED."
exit 1
