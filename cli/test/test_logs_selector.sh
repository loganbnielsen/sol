#!/usr/bin/env bash
set -euo pipefail

sol="$(realpath "${1:-}")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
check() {
  local what="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "test_logs_selector: $what: expected [$expected], got [$actual]" >&2
    fail=1
  fi
}

mkdir -p "$tmp/acme/app/payments/charge_svc" "$tmp/acme/app/comms/notify_worker" "$tmp/bin"
echo 'FROM scratch' >"$tmp/acme/app/payments/charge_svc/Dockerfile"
touch "$tmp/acme/app/payments/charge_svc/sol.toml"
echo 'FROM scratch' >"$tmp/acme/app/comms/notify_worker/Dockerfile"
touch "$tmp/acme/app/comms/notify_worker/sol.toml"
echo 'project: acme' >"$tmp/acme/sol.yml"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$CURL_ARGV_LOG"
printf '{"status":"success","data":{"result":[{"stream":{},"values":[["1","hello from the unit"]]}]}}'
printf '\n200'
EOF
chmod +x "$tmp/bin/curl"

run_logs() {
  local scope="$1"
  rm -f "$tmp/argv"
  set +e
  output="$(cd "$tmp/acme" && CURL_ARGV_LOG="$tmp/argv" PATH="$tmp/bin:$PATH" \
    "$sol" local logs --scope "$scope" --no-follow 2>&1)"
  rc=$?
  set -e
  selector="$(rg -N --no-line-number -o -P '(?<=query=).*' "$tmp/argv" 2>/dev/null || echo MISSING)"
}

run_logs payments/charge-svc
check "a unit query exits 0" 0 "$rc"
check "the printed-log query selects the unit's identity" \
  '{workspace="acme", domain="payments", service="charge-svc"}' "$selector"
case "$selector" in
  *=~*) echo "test_logs_selector: the selector is still a regex substring" >&2; fail=1 ;;
esac

run_logs comms/notify-worker
check "another unit in this workspace selects its own identity" \
  '{workspace="acme", domain="comms", service="notify-worker"}' "$selector"

run_logs payments/charge-svc

set +e
output="$(cd "$tmp/acme" && "$sol" open logs payments/charge-svc --links 2>&1)"
rc=$?
set -e
check "the unit's Explore link exits 0" 0 "$rc"
case "$output" in
  *'%7Bworkspace%3D%22acme%22%2C%20domain%3D%22payments%22%2C%20service%3D%22charge-svc%22%7D'*) ;;
  *)
    echo "test_logs_selector: the Explore link does not carry the identity selector: $output" >&2
    fail=1
    ;;
esac
case "$output" in
  *'~'*) echo "test_logs_selector: the Explore link is still a regex substring: $output" >&2; fail=1 ;;
esac

exit "$fail"
