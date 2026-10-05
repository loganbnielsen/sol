#!/usr/bin/env bash
set -euo pipefail

repo="${1:-$(git rev-parse --show-toplevel)}"
scripts="$repo/platform/local/scripts"
source "$scripts/lib/dev-endpoints.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state"

cat >"$work/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state="${SOL_DEV_ENDPOINT_TEST_STATE:?}"
case "${1:-} ${2:-}" in
  "ps --format" | "ps -a")
    for f in "$state"/running-*; do
      [ -e "$f" ] || continue
      printf '%s\n' "${f##*/running-}"
    done
    if [ "${1:-} ${2:-}" = "ps -a" ]; then
      for f in "$state"/stopped-*; do
        [ -e "$f" ] || continue
        printf '%s\n' "${f##*/stopped-}"
      done
    fi
    ;;
  "network inspect" | "network connect" | "network create")
    exit 0
    ;;
  "inspect --format")
    port="$(printf '%s' "$3" | sed -n 's/.*PortBindings "\([0-9]*\)\/tcp".*/\1/p')"
    if [ -f "$state/port-$4-$port" ]; then
      cat "$state/port-$4-$port"
    else
      printf '127.0.0.1|%s\n' "$port"
    fi
    ;;
  "run -d")
    printf 'run-d %s\n' "$*" >>"$state/invocations"
    printf 'container-id\n'
    ;;
  "run --rm")
    printf '1\n'
    ;;
  "start "*)
    touch "$state/running-$2"
    printf 'start %s\n' "$2" >>"$state/invocations"
    ;;
  "rm "*)
    rm -f "$state/running-$2"
    ;;
  "logs "* | "exec "*)
    exit 0
    ;;
  *) : ;;
esac
DOCKER

printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/curl"
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/ps"
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/nc"
chmod +x "$work/bin/docker" "$work/bin/curl" "$work/bin/ps" "$work/bin/nc"

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

run_script() {
  if PATH="$work/bin:$PATH" SOL_DEV_ENDPOINT_TEST_STATE="$work/state" \
    "$scripts/$1" >"$work/out" 2>&1; then
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

expect_bind() {
  if grep -qF -- "-p $1" "$work/state/invocations"; then ok "$2"; else bad "$2"; fi
  if ! dev_has_ipv6_loopback; then return 0; fi
  if grep -qF -- "-p [::1]:${1#127.0.0.1:}" "$work/state/invocations"; then
    ok "$2 (IPv6 loopback)"
  else
    bad "$2 (IPv6 loopback)"
  fi
}

echo "dev-endpoints: every maintained helper publishes on the loopback address"
reset_state
run_script ensure-grafana.sh
expect_exit 0 "ensure-grafana succeeds against a fake Docker"
expect_bind 127.0.0.1:3000:3000 "grafana binds loopback"

reset_state
run_script ensure-loki.sh
expect_exit 0 "ensure-loki succeeds against a fake Docker"
expect_bind 127.0.0.1:3100:3100 "loki binds loopback"

reset_state
run_script ensure-tempo.sh
expect_bind 127.0.0.1:4318:4318 "tempo binds OTLP on loopback"
expect_bind 127.0.0.1:3200:3200 "tempo binds query on loopback"

reset_state
run_script ensure-prometheus.sh
expect_exit 0 "ensure-prometheus succeeds against a fake Docker"
expect_bind 127.0.0.1:9090:9090 "prometheus binds loopback"

reset_state
run_script ensure-pushgateway.sh
expect_exit 0 "ensure-pushgateway succeeds against a fake Docker"
expect_bind 127.0.0.1:9091:9091 "pushgateway binds loopback"

reset_state
run_script ensure-postgres.sh
expect_exit 0 "ensure-postgres succeeds against a fake Docker"
expect_bind 127.0.0.1:5432:5432 "postgres binds loopback"

reset_state
run_script start-redpanda.sh
expect_exit 0 "start-redpanda succeeds against a fake Docker"
expect_bind 127.0.0.1:9092:9092 "redpanda binds Kafka on loopback"
expect_bind 127.0.0.1:9644:9644 "redpanda binds admin on loopback"
expect_bind 127.0.0.1:8081:8081 "redpanda binds schema registry on loopback"

echo
echo "dev-endpoints: an existing container published beyond loopback is refused"
reset_state
touch "$work/state/running-grafana"
printf '0.0.0.0|3000\n' >"$work/state/port-grafana-3000"
run_script ensure-grafana.sh
expect_exit 1 "a broadly published grafana fails"
expect_text "not on 127.0.0.1" "the refusal names the binding"
expect_text "docker rm -f grafana" "the refusal names the recreation"
expect_no_text "Grafana already running" "compliance is not silently accepted"

echo
echo "dev-endpoints: an unsafe stopped container is refused before it can start"
reset_state
touch "$work/state/stopped-grafana"
printf '0.0.0.0|3000\n' >"$work/state/port-grafana-3000"
run_script ensure-grafana.sh
expect_exit 1 "a stopped broadly published grafana fails"
expect_no_text "Restarting stopped Grafana" "the unsafe container is rejected before restart"
expect_no_text "start grafana" "Docker never starts the unsafe container"

echo
if [ "$failures" -eq 0 ]; then
  echo "dev-endpoints bindings: every expectation held."
  exit 0
fi
echo "dev-endpoints bindings: $failures expectation(s) FAILED."
exit 1
