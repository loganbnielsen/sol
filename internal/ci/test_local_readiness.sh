#!/usr/bin/env bash
# Behavioral guard for the shared local-service readiness policy (#1166).
#
# Every expectation below runs the real setup helper against a fake Docker and a
# fake curl. Nothing here inspects the scripts' source text: it asserts the
# outcome a user observes, so a helper that starts a container but never proves
# the endpoint works has to fail.
set -euo pipefail

repo="${1:-$(git rev-parse --show-toplevel)}"
scripts="$repo/platform/local/scripts"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state"

cat >"$work/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state="${SOL_READINESS_TEST_STATE:?}"
case "${1:-} ${2:-}" in
  "ps --format")
    for f in "$state"/running-*; do
      [ -e "$f" ] || continue
      printf '%s\n' "${f##*/running-}"
    done
    ;;
  "ps -a")
    for f in "$state"/running-*; do
      [ -e "$f" ] || continue
      printf '%s\n' "${f##*/running-}"
    done
    for f in "$state"/stopped-*; do
      [ -e "$f" ] || continue
      printf '%s\n' "${f##*/stopped-}"
    done
    ;;
  "network inspect" | "network create" | "network connect")
    printf 'network %s\n' "$*" >>"$state/invocations"
    exit 0
    ;;
  "inspect --format")
    port="$(printf '%s' "$3" | sed -n 's/.*PortBindings "\([0-9]*\)\/tcp".*/\1/p')"
    printf '127.0.0.1|%s\n' "$port"
    ;;
  "run -d")
    name=""
    prev=""
    for arg in "$@"; do
      [ "$prev" = "--name" ] && name="$arg"
      prev="$arg"
    done
    [ -n "$name" ] && touch "$state/running-$name"
    printf 'run -d %s\n' "$*" >>"$state/invocations"
    echo container-id
    ;;
  "run --rm")
    echo 1
    ;;
  "start "*)
    touch "$state/running-$2"
    printf 'start %s\n' "$2" >>"$state/invocations"
    ;;
  "logs "*)
    echo "fake container log line"
    ;;
  "exec "*)
    if [ -f "$state/exec-hang" ]; then
      sleep 30
      exit 0
    fi
    if [ -f "$state/exec-fail" ]; then
      echo "rpk: cluster is not healthy" >&2
      exit 1
    fi
    echo "HEALTHY"
    ;;
  *) : ;;
esac
DOCKER

cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
state="${SOL_READINESS_TEST_STATE:?}"
url=""
for arg in "$@"; do url="$arg"; done
printf '%s\n' "$url" >>"$state/curl.log"
if [ -f "$state/hang" ]; then
  sleep 30
  exit 0
fi
if [ -f "$state/unhealthy" ]; then
  echo "curl: (7) Failed to connect to localhost" >&2
  exit 7
fi
if [ -f "$state/healthy-after" ]; then
  want="$(cat "$state/healthy-after")"
  count=0
  [ -f "$state/curl.count" ] && count="$(cat "$state/curl.count")"
  count=$((count + 1))
  printf '%s' "$count" >"$state/curl.count"
  if [ "$count" -ge "$want" ]; then
    exit 0
  fi
  echo "curl: (7) Failed to connect to localhost" >&2
  exit 7
fi
exit 0
CURL

printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/ps"
chmod +x "$work/bin/docker" "$work/bin/curl" "$work/bin/ps"

export PATH="$work/bin:$PATH"
export SOL_READINESS_TEST_STATE="$work/state"
export READINESS_TIMEOUT_S=2
export READINESS_INTERVAL_S=1
export READINESS_PROBE_TIMEOUT_S=1

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

status=0
run_script() {
  local start=$SECONDS
  if "$scripts/$1" >"$work/out" 2>&1; then
    status=0
  else
    status=$?
  fi
  last_elapsed=$((SECONDS - start))
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

expect_bounded() {
  if [ "$last_elapsed" -lt "$1" ]; then
    ok "$2 (took ${last_elapsed}s)"
  else
    bad "$2 (took ${last_elapsed}s, expected under ${1}s)"
  fi
}

echo "local readiness: an exhausted probe cannot be reported as success"
reset_state
touch "$work/state/unhealthy"
run_script ensure-tempo.sh
expect_exit 1 "an unhealthy Tempo fails"
expect_no_text "OTLP/HTTP ingestion" "Tempo never advertises its endpoint"
expect_text "Tempo was not ready" "the failure names the readiness timeout"

reset_state
touch "$work/state/unhealthy"
run_script ensure-prometheus.sh
expect_exit 1 "an unhealthy Prometheus fails"
expect_no_text "Prometheus  ->" "Prometheus never advertises its endpoint"

reset_state
touch "$work/state/unhealthy"
run_script ensure-pushgateway.sh
expect_exit 1 "an unhealthy Pushgateway fails"
expect_no_text "Pushgateway ->" "Pushgateway never advertises its endpoint"

reset_state
touch "$work/state/unhealthy"
run_script ensure-grafana.sh
expect_exit 1 "an unhealthy Grafana fails"
expect_no_text "Datasources provisioned" "no datasource is provisioned without Grafana"

reset_state
touch "$work/state/unhealthy"
run_script ensure-loki.sh
expect_exit 1 "an unhealthy Loki fails"

echo
echo "local readiness: a healthy or eventually-healthy service is accepted"
reset_state
run_script ensure-tempo.sh
expect_exit 0 "an immediately healthy Tempo succeeds"
expect_text "OTLP/HTTP ingestion" "Tempo advertises its endpoint"
expect_text "Connecting tempo to sol-obs" "healthy Tempo reaches the post-readiness network reconciliation"

reset_state
printf '3' >"$work/state/healthy-after"
run_script ensure-tempo.sh
expect_exit 0 "an eventually healthy Tempo succeeds"
expect_text "— ready" "readiness is reported after the probe succeeds"
if [ "$(cat "$work/state/curl.count")" -ge 3 ]; then
  ok "the probe retried until it succeeded"
else
  bad "the probe did not retry"
fi

echo
echo "local readiness: an already-running but unhealthy container is not trusted"
reset_state
touch "$work/state/running-tempo" "$work/state/unhealthy"
run_script ensure-tempo.sh
expect_exit 1 "a reused unhealthy Tempo fails"
expect_no_text "OTLP/HTTP ingestion" "reuse does not stand in for readiness"

echo
echo "local readiness: a hung probe is bounded by wall clock"
reset_state
touch "$work/state/hang"
run_script ensure-tempo.sh
expect_exit 1 "a hanging Tempo probe fails"
expect_bounded 10 "the hung probe did not stall the helper"

reset_state
touch "$work/state/exec-hang"
run_script start-redpanda.sh
expect_exit 1 "a hanging broker health probe fails"
expect_bounded 10 "the hung broker probe did not stall the helper"

echo
echo "local readiness: a broker that cannot report healthy is refused"
reset_state
touch "$work/state/exec-fail"
run_script start-redpanda.sh
expect_exit 1 "an unhealthy broker fails"
expect_no_text "broker — ready" "the broker is not reported ready"

echo
if [ "$failures" -eq 0 ]; then
  echo "local readiness: every expectation held."
  exit 0
fi
echo "local readiness: $failures expectation(s) FAILED."
exit 1
