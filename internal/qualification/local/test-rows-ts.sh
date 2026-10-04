#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$HERE/rows-ts.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOG_DIR="$TMP/log"
STATE="$TMP/state"
mkdir -p "$LOG_DIR" "$STATE"

pass=0
ok() {
  printf '  [OK]   %s\n' "$1"
  pass=$((pass + 1))
}
bad() {
  printf '  [FAIL] %s\n' "$1" >&2
  exit 1
}

reset_state() {
  : >"$STATE/orders"
  : >"$STATE/jobs"
  : >"$STATE/outbox"
  : >"$STATE/fulfilled"
  : >"$STATE/confirmations"
  : >"$STATE/dlq"
  : >"$STATE/reads"
  : >"$STATE/topic_fulfilled"
  printf '0\n' >"$STATE/decode_errors"
  printf '1\n' >"$STATE/broker_up"
  rm -rf "$LOG_DIR/rows"
  unset STUB_LEAK_DUPLICATE STUB_BREAK_CONFIRM STUB_NO_DLQ STUB_REPUBLISH_DUPLICATE
}

source "$DRIVER"

POLL_TIMEOUT_S=4
POLL_INTERVAL_S=0.01
HTTP_POLL_INTERVAL_S=0.01
CONSUME_TIMEOUT_S=1

deploy_scopes() { return 0; }
sleep_s() { sleep "$1"; }

sim_reads() {
  local id="$1" reads
  reads="$(awk -F'|' -v id="$id" '$1 == id { print $2 }' "$STATE/reads")"
  reads="${reads:-0}"
  reads=$((reads + 1))
  if grep -q "^$id|" "$STATE/reads"; then
    sed -i "s/^$id|.*/$id|$reads/" "$STATE/reads"
  else
    printf '%s|%s\n' "$id" "$reads" >>"$STATE/reads"
  fi
  if [ "${STUB_BREAK_CONFIRM:-0}" = 1 ]; then printf 'accepted'; return 0; fi
  if [ "$reads" -ge 2 ] && ! grep -q "^$id|" "$STATE/fulfilled"; then
    printf '%s|\n' "$id" >>"$STATE/fulfilled"
    printf '%s|release_inventory\n' "$id" >>"$STATE/jobs"
    printf '{"order_id":"%s"}\n' "$id" >>"$STATE/topic_fulfilled"
  fi
  if [ "$reads" -ge 3 ] && ! grep -q "^$id|" "$STATE/confirmations"; then
    printf '%s|\n' "$id" >>"$STATE/confirmations"
  fi
  if [ "$reads" -ge 3 ]; then
    printf 'confirmed'
  elif [ "$reads" -eq 2 ]; then
    printf 'fulfilled'
  else
    printf 'accepted'
  fi
}

http_request() {
  local method="$1" path="$2" body="${3:-}"
  if [ "$method" = GET ]; then
    local id="${path##*/}"
    if grep -q "^$id|" "$STATE/orders"; then
      printf '{"order_id":"%s","item":"widget","quantity":3,"status":"%s"}\n200' \
        "$id" "$(sim_reads "$id")"
    else
      printf '{}\n404'
    fi
    return 0
  fi
  local id
  id="$(printf '%s' "$body" | sed -n 's/.*"order_id":"\([^"]*\)".*/\1/p')"
  if grep -q "^$id|" "$STATE/orders"; then
    if [ "${STUB_LEAK_DUPLICATE:-0}" = 1 ]; then
      printf '%s|send_confirmation\n' "$id" >>"$STATE/jobs"
    fi
    printf '{"order_id":"%s","status":"%s"}\n202' \
      "$id" "$(awk -F'|' -v id="$id" '$1 == id { print $2 }' "$STATE/orders")"
    return 0
  fi
  if grep -q "^$id|OrderPlaced|1|" "$STATE/outbox"; then
    printf '{"error":"injected"}\n500'
    return 0
  fi
  printf '%s|accepted\n' "$id" >>"$STATE/orders"
  printf '%s|send_confirmation\n' "$id" >>"$STATE/jobs"
  if [ "$(cat "$STATE/broker_up")" = 0 ]; then
    printf '%s|OrderPlaced|1|{}\n' "$id" >>"$STATE/outbox"
  fi
  printf '{"order_id":"%s","status":"accepted"}\n202' "$id"
}

sql_id() { printf '%s' "$1" | sed -n "s/.*order_id = '\([^']*\)'.*/\1/p"; }
sql_key() { printf '%s' "$1" | sed -n "s/.*aggregate_key = '\([^']*\)'.*/\1/p"; }
sql_dedupe() { printf '%s' "$1" | sed -n "s/.*dedupe_key = '\([^']*\)'.*/\1/p"; }
sql_kind() { printf '%s' "$1" | sed -n "s/.*kind = '\([^']*\)'.*/\1/p"; }

db_scalar() {
  local sql="$1" id kind
  case "$sql" in
    *"SELECT status FROM orders_ts"*)
      id="$(sql_id "$sql")"
      if grep -q "^$id|" "$STATE/orders"; then sim_reads "$id"; fi
      ;;
    *"FROM sol_jobs"*)
      id="$(sql_dedupe "$sql")"
      kind="$(sql_kind "$sql")"
      grep -c "^$id|$kind$" "$STATE/jobs" || true
      ;;
    *"FROM sol_outbox"*)
      id="$(sql_key "$sql")"
      grep -c "^$id|" "$STATE/outbox" || true
      ;;
    *"FROM fulfilled_orders_ts"*)
      id="$(sql_id "$sql")"
      grep -c "^$id|" "$STATE/fulfilled" || true
      ;;
    *"FROM order_confirmations_ts"*)
      id="$(sql_id "$sql")"
      grep -c "^$id|" "$STATE/confirmations" || true
      ;;
    *"SELECT count(*) FROM orders_ts"*)
      id="$(sql_id "$sql")"
      grep -c "^$id|" "$STATE/orders" || true
      ;;
    *) printf '' ;;
  esac
}

db_exec() {
  local sql="$1" id
  case "$sql" in
    *"INSERT INTO sol_outbox"*)
      id="$(printf '%s' "$sql" | sed -n "s/.*'OrderPlaced', '\([^']*\)'.*/\1/p")"
      printf '%s|OrderPlaced|1|{}\n' "$id" >>"$STATE/outbox"
      ;;
    *"DELETE FROM sol_outbox"*)
      id="$(printf '%s' "$sql" | sed -n "s/.*aggregate_key = '\([^']*\)'.*/\1/p")"
      grep -v "^$id|OrderPlaced|1|{}$" "$STATE/outbox" >"$STATE/outbox.tmp" || true
      mv "$STATE/outbox.tmp" "$STATE/outbox"
      ;;
    *) : ;;
  esac
}

topic_produce() {
  local topic="$1" key="$2" payload="$3"
  if [ "$topic" = "$ORDERS_TOPIC" ]; then
    case "$payload" in
      *'"order_id"'*)
        if ! grep -q "^$key|" "$STATE/fulfilled"; then
          printf '%s|\n' "$key" >>"$STATE/fulfilled"
          printf '%s|release_inventory\n' "$key" >>"$STATE/jobs"
          printf '{"order_id":"%s"}\n' "$key" >>"$STATE/topic_fulfilled"
        elif [ "${STUB_REPUBLISH_DUPLICATE:-0}" = 1 ]; then
          printf '{"order_id":"%s"}\n' "$key" >>"$STATE/topic_fulfilled"
        fi
        ;;
      *)
        if [ "${STUB_NO_DLQ:-0}" != 1 ]; then
          printf '%s\n' "$payload" >>"$STATE/dlq"
          printf '%s\n' "$(( $(cat "$STATE/decode_errors") + 1 ))" >"$STATE/decode_errors"
        fi
        ;;
    esac
  fi
}

topic_records() {
  if [ "$1" = "$FULFILLED_TOPIC" ]; then
    cat "$STATE/topic_fulfilled"
  else
    cat "$STATE/dlq"
  fi
}

prom_sum() { cat "$STATE/decode_errors"; }

broker_scale() {
  if [ "$1" = 0 ]; then
    printf '0\n' >"$STATE/broker_up"
  else
    printf '1\n' >"$STATE/broker_up"
    : >"$STATE/outbox"
  fi
}

restart_deploys() { :; }

run() {
  local row="$1"
  RUN_RC=0
  LOG_DIR="$LOG_DIR" run_row "$row" >"$TMP/run-$row.out" 2>&1 || RUN_RC=$?
  RUN_LOG="$LOG_DIR/rows/ts-$row.txt"
}

expect_ok() { [ "$RUN_RC" -eq 0 ] || bad "$1 (exit $RUN_RC): $(tail -n 5 "$TMP/run-$1.out" | tr '\n' '|')"; }
expect_fail() { [ "$RUN_RC" -ne 0 ] || bad "$1 (expected non-zero, got 0)"; }
names() { grep -qF -- "$2" "$RUN_LOG" || bad "$3 (wanted: $2)"; }

if [ "$(dlq_topic)" != "sol-demo-ts-orders.sol-demo-ts-fulfillment-worker-a239c8cce37d.dlq" ]; then
  bad "the DLQ topic name must match canonical_group_segment (got: $(dlq_topic))"
fi
ok "the DLQ topic name matches the group-scoped canonical segment"

for row in b1 b2 b5 b6 d5 h1
do
  reset_state
  run "$row"
  expect_ok "$row passes on a correct implementation"
  names "the $row log records a PASS verdict" $'verdict\tPASS' "the $row verdict is recorded"
done
ok "every row passes against a correct implementation and records its verdict"

reset_state
run_row bogus >"$TMP/bogus.out" 2>&1
[ "$?" -ne 0 ] || bad "an unknown row must fail"
ok "an unknown row fails instead of reporting success"

reset_state
export STUB_LEAK_DUPLICATE=1
run b1
expect_fail "B1 (TS) fails when a duplicate POST leaks a second job"
names "mutated B1" "B1 (TS) exactly one send_confirmation job" "the failure names the leaked job"
ok "B1 (TS) fails for the reason under test when a duplicate leaks an effect"

reset_state
export STUB_BREAK_CONFIRM=1
run b5
expect_fail "B5 (TS) fails when the read-back never reaches confirmed"
names "mutated B5" "B5 (TS) the read-back reaches confirmed" "the failure names the read-back"
ok "B5 (TS) fails for the reason under test when the read-back stalls"

reset_state
export STUB_NO_DLQ=1
run d5
expect_fail "D5 (TS) fails when the DLQ record is missing"
names "mutated D5" "D5 (TS) the DLQ topic receives the raw record" "the failure names the DLQ"
ok "D5 (TS)/H1 fails for the reason under test when the DLQ record is missing"

reset_state
export STUB_REPUBLISH_DUPLICATE=1
run b6
expect_fail "B6 (TS) fails when a redelivery republishes the fact"
names "mutated B6" "B6 (TS) the duplicate publishes no second OrderFulfilled" \
  "the failure names the second publication"
ok "B6 (TS) fails for the reason under test when a redelivery republishes"

mkdir -p "$TMP/tools"
for tool in curl psql rpk jq kubectl md5sum
do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/tools/$tool"
  chmod +x "$TMP/tools/$tool"
done

reset_state
SAVED_CURL="$CURL" SAVED_PSQL="$PSQL" SAVED_RPK="$RPK"
SAVED_JQ="$JQ" SAVED_KUBECTL="$KUBECTL" SAVED_MD5SUM="$MD5SUM"
CURL="$TMP/tools/curl"
PSQL="$TMP/tools/psql"
RPK="$TMP/tools/rpk"
JQ="$TMP/tools/jq"
KUBECTL="$TMP/tools/kubectl"
MD5SUM="$TMP/tools/md5sum"
LOG_DIR="$LOG_DIR" main b2 >"$TMP/main-ok.out" 2>&1
MAIN_RC=$?
CURL="$SAVED_CURL"
PSQL="$SAVED_PSQL"
RPK="$SAVED_RPK"
JQ="$SAVED_JQ"
KUBECTL="$SAVED_KUBECTL"
MD5SUM="$SAVED_MD5SUM"
[ "$MAIN_RC" -eq 0 ] || bad "main runs when every tool resolves (exit $MAIN_RC)"
ok "main runs once every row-driver tool resolves"

reset_state
PSQL="$TMP/tools/absent-psql"
LOG_DIR="$LOG_DIR" main b2 >"$TMP/main-missing.out" 2>&1
MAIN_RC=$?
PSQL="$SAVED_PSQL"
[ "$MAIN_RC" -ne 0 ] || bad "main must fail closed when a tool is missing"
grep -qF 'QUAL_PSQL=' "$TMP/main-missing.out" || bad "the missing tool is named"
ok "main fails closed and names a missing row-driver tool"

echo
echo "test-rows-ts: all expectations hold ($pass checks)."
