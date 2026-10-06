#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"

pass=0
fail=0
ok() { printf '  [OK]   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  [FAIL] %s\n           expected: %s\n           actual:   %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$3" "$2"; fi; }
has() { if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else no "$1" "contains: $2" "absent"; fi; }

cat >"$BIN/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"${KUBECTL_LOG:-/dev/null}"
case " $* " in
  *" port-forward "*)
    printf 'Forwarding from 127.0.0.1:54321 -> 80\n'
    while true; do sleep 1; done
    ;;
  *" logs tx-pod"*) cat "${STUB_TX_LOG:-/dev/null}" ;;
  *" get pods -l job-name="*) printf 'tx-pod' ;;
esac
exit 0
STUB
chmod +x "$BIN/kubectl"

cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${CURL_LOG:-/dev/null}"
charge="${STUB_CHARGE-}"
[ -n "$charge" ] || charge='{"id":"ch_1","accepted":true}'
notifications="${STUB_NOTIFICATIONS-}"
[ -n "$notifications" ] || notifications='[{"charge_id":"ch_1"}]'
case "$*" in
  *"/health"*) printf '%s\n' "${STUB_HEALTH:-ok}" ;;
  *" -X POST "*"/charges"*) printf '%s\n' "$charge" ;;
  *"/notifications"*) printf '%s\n' "$notifications" ;;
  *" -X POST "*"/orders"*)
    body=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -d)
          body="$2"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    id="$(printf '%s' "$body" | sed -n 's/.*"order_id":"\([^"]*\)".*/\1/p')"
    printf '{"order_id":"%s","status":"pending"}\n' "$id"
    ;;
  *"/orders/"*)
    url="${!#}"
    id="${url##*/}"
    printf '{"order_id":"%s","status":"%s"}\n' "${STUB_ORDER_READBACK_ID:-$id}" "${STUB_ORDER_STATUS:-fulfilled}"
    ;;
  *) printf '{}\n' ;;
esac
exit 0
STUB
chmod +x "$BIN/curl"

export PATH="$BIN:$PATH"
export KUBECTL_LOG="$TMP/kubectl.log"
export CURL_LOG="$TMP/curl.log"

run_app() {
  local fixture="$1" dir
  dir="$TMP/app-$(basename "$fixture")"
  mkdir -p "$dir"
  STUB_TX_LOG="$fixture" bash "$HERE/app-transaction.sh" "$dir" >"$dir/out" 2>&1
  echo "$?"
}

run_transport() {
  local name="$1" dir
  shift
  dir="$TMP/tx-$name"
  mkdir -p "$dir"
  env KUBECONFIG_TRANSPORT="$TMP/kubeconfig" READBACK_INTERVAL=0 READBACK_ATTEMPTS=2 "$@" \
    bash "$HERE/transport-transaction.sh" "$dir" >"$dir/out" 2>&1
  echo "$?"
}

# --- in-cluster Job-log path -------------------------------------------------

printf '%s\n' \
  'SOL_TRANSACTION charge {"id":"ch_1","accepted":true}' \
  'SOL_TRANSACTION notifications [{"charge_id":"ch_2"}]' \
  'SOL_TRANSACTION notifications [{"charge_id":"ch_1"}]' >"$TMP/success.log"
is "in-cluster: an exact read-back succeeds" "0" "$(run_app "$TMP/success.log")"
has "in-cluster: and the verdict records the identity" \
  "read-back: the worker effect ch_1 is visible" "$TMP/app-success.log/app-transaction.txt"

printf '%s\n' \
  'SOL_TRANSACTION charge {"id":"","accepted":true}' \
  'SOL_TRANSACTION notifications []' >"$TMP/empty.log"
is "in-cluster: an empty operation id cannot pass" "1" "$(run_app "$TMP/empty.log")"

printf '%s\n' \
  'SOL_TRANSACTION charge {"id":"ch_1","accepted":true}' \
  'SOL_TRANSACTION notifications [{"charge_id":"ch_10"}]' >"$TMP/substring.log"
is "in-cluster: a longer id is not a substring match" "1" "$(run_app "$TMP/substring.log")"

printf '%s\n' \
  'SOL_TRANSACTION charge {"id":"ch_1","accepted":true}' \
  'SOL_TRANSACTION notifications not-json' >"$TMP/malformed.log"
is "in-cluster: a malformed read-back fails" "1" "$(run_app "$TMP/malformed.log")"

printf '%s\n' \
  'SOL_TRANSACTION notifications [{"charge_id":"ch_1"}]' >"$TMP/nocharge.log"
is "in-cluster: a missing operation response fails" "1" "$(run_app "$TMP/nocharge.log")"

# --- transport path ----------------------------------------------------------

is "transport charges: an exact read-back succeeds" "0" \
  "$(run_transport charges-ok env SCENARIO=charges)"
has "transport charges: and the verdict records the effect" \
  "read-back: the worker effect is visible" "$TMP/tx-charges-ok/transport-transaction.txt"

is "transport charges: an empty operation id fails" "1" \
  "$(run_transport charges-empty env SCENARIO=charges STUB_CHARGE='{"id":""}')"

is "transport charges: an unrelated read-back fails" "1" \
  "$(run_transport charges-unrelated env SCENARIO=charges STUB_NOTIFICATIONS='[{"charge_id":"ch_other"}]')"

is "transport charges: a malformed read-back fails" "1" \
  "$(run_transport charges-malformed env SCENARIO=charges STUB_NOTIFICATIONS='not-json')"

is "transport orders: a matching success status succeeds" "0" \
  "$(run_transport orders-ok env SCENARIO=orders STUB_ORDER_STATUS=confirmed)"
has "transport orders: and the verdict records the effect" \
  "read-back: the worker effect is visible" "$TMP/tx-orders-ok/transport-transaction.txt"

is "transport orders: a pending status fails" "1" \
  "$(run_transport orders-pending env SCENARIO=orders STUB_ORDER_STATUS=pending)"

is "transport orders: a mismatched read-back id fails" "1" \
  "$(run_transport orders-mismatch env SCENARIO=orders STUB_ORDER_READBACK_ID=ord-somebody-else)"

printf '\ntransaction path tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
