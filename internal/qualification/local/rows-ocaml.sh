#!/usr/bin/env bash
set -uo pipefail

CURL="${QUAL_CURL:-curl}"
JQ="${QUAL_JQ:-jq}"
PSQL="${QUAL_PSQL:-psql}"
RPK="${QUAL_RPK:-rpk}"
KUBECTL="${QUAL_KUBECTL:-kubectl}"
MD5SUM="${QUAL_MD5SUM:-md5sum}"

SOL="${SOL:-sol}"
WORKSPACE="${WORKSPACE:-}"
LOG_DIR="${LOG_DIR:-}"

INGRESS_URL="${ORDERS_INGRESS_URL:-http://localhost:8088}"
ORDERS_HOST="${ORDERS_HOST:-orders-svc.pluto-payments.localhost}"
ORDERS_PATH="${ORDERS_PATH:-/orders}"
POSTGRES_URL="${POSTGRES_URL:-postgresql://postgres:dev@localhost:5432/sol_dev}"
KAFKA_BROKERS="${KAFKA_BROKERS:-localhost:9092}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
ORDERS_TOPIC="${ORDERS_TOPIC:-orders.v1}"
FULFILLED_TOPIC="${FULFILLED_TOPIC:-orders-fulfilled.v1}"
ORDERS_GROUP_ID="${ORDERS_GROUP_ID:-pluto-orders-fulfilment-worker}"
ORDERS_WORKSPACE="${ORDERS_WORKSPACE:-pluto.orders}"
ORDERS_NS="${ORDERS_NS:-pluto-payments}"
FULFIL_NS="${FULFIL_NS:-pluto-comms}"
BROKER_NS="${BROKER_NS:-redpanda}"
BROKER_STATEFULSET="${BROKER_STATEFULSET:-redpanda}"
HTTP_TIMEOUT_S="${HTTP_TIMEOUT_S:-30}"
POLL_INTERVAL_S="${POLL_INTERVAL_S:-1}"
POLL_TIMEOUT_S="${POLL_TIMEOUT_S:-90}"
HTTP_POLL_INTERVAL_S="${HTTP_POLL_INTERVAL_S:-0.2}"
CONSUME_TIMEOUT_S="${CONSUME_TIMEOUT_S:-6}"
SKIP_DEPLOY="${ROWS_OCAML_SKIP_DEPLOY:-0}"

ROW_FAILURES=0
CURRENT_LOG=""

usage() {
  printf 'usage: rows-ocaml.sh [row ...]\n\n'
  printf 'rows: b1 b2 b5 b6 d5 h1 h2 all\n\n'
  printf 'environment: SOL WORKSPACE LOG_DIR (from local-qual.sh rows), plus\n'
  printf '  ORDERS_INGRESS_URL ORDERS_HOST POSTGRES_URL KAFKA_BROKERS PROMETHEUS_URL\n'
  printf '  ORDERS_TOPIC FULFILLED_TOPIC ORDERS_GROUP_ID ORDERS_NS FULFIL_NS\n'
  printf '  BROKER_NS BROKER_STATEFULSET ROWS_OCAML_SKIP_DEPLOY\n'
  printf 'tools: curl, jq, psql, rpk, kubectl (override with QUAL_CURL, QUAL_JQ, QUAL_PSQL, QUAL_RPK, QUAL_KUBECTL)\n'
}

row_say() { printf '[rows-ocaml %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

log_cmd() {
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
  } >>"$CURRENT_LOG"
}

pass() { printf 'ok: %s\n' "$1" >>"$CURRENT_LOG"; }

fail_row() {
  printf 'FAIL: %s\n' "$1" >>"$CURRENT_LOG"
  row_say "FAIL: $1"
  ROW_FAILURES=$((ROW_FAILURES + 1))
}

check_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail_row "$1: expected [$2], observed [$3]"; fi
}

check_ge() {
  if [ "$3" -ge "$2" ] 2>/dev/null; then pass "$1"; else fail_row "$1: expected >= [$2], observed [$3]"; fi
}

http_request() {
  local method="$1" path="$2" body="${3:-}"
  log_cmd "$CURL" "$method" "$INGRESS_URL$path" "Host=$ORDERS_HOST" "$body"
  if [ "$method" = POST ]; then
    "$CURL" -sS -m "$HTTP_TIMEOUT_S" -H "Host: $ORDERS_HOST" \
      -H 'content-type: application/json' -w '\n%{http_code}' \
      -X POST -d "$body" "$INGRESS_URL$path"
  else
    "$CURL" -sS -m "$HTTP_TIMEOUT_S" -H "Host: $ORDERS_HOST" -w '\n%{http_code}' \
      "$INGRESS_URL$path"
  fi
}

status_of() { printf '%s' "$1" | tail -n 1; }
body_of() { printf '%s\n' "$1" | sed '$d'; }
status_field() { body_of "$1" | "$JQ" -r '.status // empty' 2>/dev/null; }

db_scalar() {
  log_cmd "$PSQL" "$POSTGRES_URL" -tAc "$1"
  "$PSQL" "$POSTGRES_URL" -tAc "$1" 2>>"$CURRENT_LOG" | tr -d '[:space:]'
}

db_exec() {
  log_cmd "$PSQL" "$POSTGRES_URL" -c "$1"
  "$PSQL" "$POSTGRES_URL" -c "$1" >>"$CURRENT_LOG" 2>&1
}

topic_produce() {
  log_cmd "$RPK" topic produce "$1" "-k" "$2"
  printf '%s\n' "$3" | "$RPK" -X "brokers=$KAFKA_BROKERS" topic produce "$1" -k "$2" \
    >>"$CURRENT_LOG" 2>&1
}

topic_records() {
  log_cmd "timeout $CONSUME_TIMEOUT_S" "$RPK" topic consume "$1" "-o" start
  timeout "$CONSUME_TIMEOUT_S" "$RPK" -X "brokers=$KAFKA_BROKERS" topic consume "$1" \
    -o start -f '%v\n' 2>>"$CURRENT_LOG" || true
}

prom_query() {
  "$CURL" -sS -m "$HTTP_TIMEOUT_S" --data-urlencode "query=$1" \
    "$PROMETHEUS_URL/api/v1/query" 2>>"$CURRENT_LOG" |
    "$JQ" -r '[.data.result[]?.value[1] | tonumber] | add // 0' 2>>"$CURRENT_LOG"
}

prom_sum() {
  log_cmd "$CURL" "$PROMETHEUS_URL/api/v1/query" "$1"
  prom_query "$1"
}

prom_advanced() { [ "$(prom_query "$1")" -gt "$2" ] 2>/dev/null; }

broker_scale() {
  log_cmd "$KUBECTL" -n "$BROKER_NS" scale "statefulset/$BROKER_STATEFULSET" "--replicas=$1"
  "$KUBECTL" -n "$BROKER_NS" scale "statefulset/$BROKER_STATEFULSET" "--replicas=$1" \
    >>"$CURRENT_LOG" 2>&1
}

restart_deploys() {
  local ns="$1" selector="$2"
  log_cmd "$KUBECTL" -n "$ns" rollout restart "deploy" "-l" "$selector"
  "$KUBECTL" -n "$ns" rollout restart deploy -l "$selector" >>"$CURRENT_LOG" 2>&1
}

sleep_s() { sleep "$1"; }

wait_until() {
  local label="$1" timeout="$2"
  shift 2
  local waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if "$@" >/dev/null 2>&1; then pass "$label"; return 0; fi
    sleep_s "$POLL_INTERVAL_S"
    waited=$((waited + 1))
  done
  fail_row "$label: not satisfied after ${timeout}s"
  return 1
}

sha12() { printf '%s' "$1" | "$MD5SUM" | cut -c1-12; }

group_segment() {
  local sanitized
  sanitized="$(printf '%s' "$1" | tr -c 'a-zA-Z0-9-' '-' | cut -c1-51)"
  printf '%s-%s' "$sanitized" "$(sha12 "$1")"
}

dlq_topic() { printf '%s.%s.dlq' "$ORDERS_TOPIC" "$(group_segment "$ORDERS_GROUP_ID")"; }

new_order_id() { printf 'qual-%s-%s' "$1" "$(date -u +%Y%m%d%H%M%S)"; }

order_body() { printf '{"order_id":"%s","item":"widget","quantity":3}' "$1"; }

orders_count() { db_scalar "SELECT count(*) FROM orders WHERE order_id = '$1'"; }

jobs_count() {
  db_scalar "SELECT count(*) FROM sol_jobs WHERE workspace = '$ORDERS_WORKSPACE' \
    AND kind = '$2' AND dedupe_key = '$1'"
}

pending_count() { db_scalar "SELECT count(*) FROM sol_outbox WHERE aggregate_key = '$1'"; }

fulfilled_count() { db_scalar "SELECT count(*) FROM fulfilled_orders WHERE order_id = '$1'"; }

confirmations_count() {
  db_scalar "SELECT count(*) FROM order_confirmations WHERE order_id = '$1'"
}

order_status() { db_scalar "SELECT status FROM orders WHERE order_id = '$1'"; }

pending_drained() { [ "$(pending_count "$1")" = 0 ]; }

dlq_has_record() { [ "$(topic_records "$1" | wc -l | tr -d ' ')" -ge 1 ]; }

fulfilled_published_count() {
  topic_records "$FULFILLED_TOPIC" | grep -c "\"order_id\":\"$1\"" || true
}

fulfilled_published() { [ "$(fulfilled_published_count "$1")" -ge 1 ]; }

await_status() {
  local id="$1" want="$2" timeout="$3" waited=0 current=""
  while [ "$waited" -lt "$timeout" ]; do
    current="$(order_status "$id")"
    printf 'status[%ss]\t%s\n' "$waited" "$current" >>"$CURRENT_LOG"
    if [ "$current" = "$want" ]; then
      printf '%s' "$current"
      return 0
    fi
    sleep_s "$HTTP_POLL_INTERVAL_S"
    waited=$((waited + 1))
  done
  printf '%s' "$current"
  return 1
}

observe_read_back() {
  local id="$1"
  local response body status
  response="$(http_request GET "$ORDERS_PATH/$id")"
  body="$(body_of "$response")"
  status="$(status_of "$response")"
  printf 'GET %s/%s\t%s\t%s\n' "$ORDERS_PATH" "$id" "$status" "$body" >>"$CURRENT_LOG"
  if [ "$status" = 200 ]; then "$JQ" -r '.status // empty' <<<"$body" 2>/dev/null; fi
}

deploy_workspace() {
  if [ "$SKIP_DEPLOY" = 1 ]; then return 0; fi
  [ -n "$WORKSPACE" ] || { fail_row "WORKSPACE is not set, so the workspace cannot be deployed"; return 1; }
  mkdir -p "$LOG_DIR/rows"
  log_cmd "(cd $WORKSPACE && $SOL up)"
  if ( cd "$WORKSPACE" && "$SOL" up ) >>"$LOG_DIR/rows/deploy.txt" 2>&1; then
    pass "deployed $WORKSPACE with sol up"
  else
    fail_row "sol up failed; see $LOG_DIR/rows/deploy.txt"
    return 1
  fi
}

row_b1() {
  local id response duplicate
  id="$(new_order_id b1)"
  printf 'order_id\t%s\n' "$id" >>"$CURRENT_LOG"
  response="$(http_request POST "$ORDERS_PATH" "$(order_body "$id")")"
  printf 'POST %s\t%s\t%s\n' "$ORDERS_PATH" "$(status_of "$response")" "$(body_of "$response")" >>"$CURRENT_LOG"
  check_eq "B1 POST /orders returns 202" 202 "$(status_of "$response")"
  check_eq "B1 POST /orders reports accepted" accepted "$(status_field "$response")"
  duplicate="$(http_request POST "$ORDERS_PATH" "$(order_body "$id")")"
  printf 'POST duplicate\t%s\t%s\n' "$(status_of "$duplicate")" "$(body_of "$duplicate")" >>"$CURRENT_LOG"
  check_eq "B1 duplicate POST returns 202" 202 "$(status_of "$duplicate")"
  check_eq "B1 duplicate POST is idempotent" "$(status_field "$response")" "$(status_field "$duplicate")"
  check_eq "B1 exactly one orders row" 1 "$(orders_count "$id")"
  check_eq "B1 exactly one send_confirmation job" 1 "$(jobs_count "$id" send_confirmation)"
  wait_until "B1 the relay drains the key's outbox" "$POLL_TIMEOUT_S" pending_drained "$id"
}

row_b2() {
  local id response
  id="$(new_order_id b2)"
  printf 'order_id\t%s\n' "$id" >>"$CURRENT_LOG"
  db_exec "INSERT INTO sol_outbox (kind, aggregate_key, ord, payload) \
    VALUES ('OrderPlaced', '$id', 1, '{}') ON CONFLICT DO NOTHING"
  response="$(http_request POST "$ORDERS_PATH" "$(order_body "$id")")"
  printf 'POST %s\t%s\t%s\n' "$ORDERS_PATH" "$(status_of "$response")" "$(body_of "$response")" >>"$CURRENT_LOG"
  check_eq "B2 the injected intent collision fails the request" 500 "$(status_of "$response")"
  check_eq "B2 no orders row survives the rollback" 0 "$(orders_count "$id")"
  check_eq "B2 no job survives the rollback" 0 "$(jobs_count "$id" send_confirmation)"
  db_exec "DELETE FROM sol_outbox WHERE kind = 'OrderPlaced' AND aggregate_key = '$id' \
    AND ord = 1 AND payload = '{}'"
}

passed_through_fulfilled() {
  db_scalar "SELECT accepted_at IS NOT NULL AND fulfilled_at IS NOT NULL \
    AND confirmed_at IS NOT NULL AND accepted_at <= fulfilled_at \
    AND fulfilled_at <= confirmed_at FROM orders WHERE order_id = '$1'"
}

row_b5() {
  local id response terminal observed
  id="$(new_order_id b5)"
  printf 'order_id\t%s\n' "$id" >>"$CURRENT_LOG"
  response="$(http_request POST "$ORDERS_PATH" "$(order_body "$id")")"
  printf 'POST %s\t%s\t%s\n' "$ORDERS_PATH" "$(status_of "$response")" "$(body_of "$response")" >>"$CURRENT_LOG"
  check_eq "B5 POST /orders returns 202" 202 "$(status_of "$response")"
  terminal="$(await_status "$id" confirmed "$POLL_TIMEOUT_S")"
  check_eq "B5 the read-back reaches confirmed" confirmed "$terminal"
  observed="$(grep -c $'\tfulfilled$' "$CURRENT_LOG")"
  printf 'fulfilled read-back samples observed\t%s\n' "$observed" >>"$CURRENT_LOG"
  check_eq "B5 the order's persisted state passed accepted -> fulfilled -> confirmed" t \
    "$(passed_through_fulfilled "$id")"
  check_eq "B5 the read-back field agrees with the row" confirmed "$(observe_read_back "$id")"
  check_eq "B5 exactly one fulfilled_orders row" 1 "$(fulfilled_count "$id")"
  check_eq "B5 exactly one order_confirmations row" 1 "$(confirmations_count "$id")"
  check_eq "B5 exactly one release_inventory job" 1 "$(jobs_count "$id" release_inventory)"
  check_eq "B5 exactly one send_confirmation job" 1 "$(jobs_count "$id" send_confirmation)"
  wait_until "B5 the relays drain the key's outbox" "$POLL_TIMEOUT_S" pending_drained "$id"
}

row_b6() {
  local id response duplicate_payload published_before published_after
  id="$(new_order_id b6)"
  printf 'order_id\t%s\n' "$id" >>"$CURRENT_LOG"
  response="$(http_request POST "$ORDERS_PATH" "$(order_body "$id")")"
  printf 'POST %s\t%s\t%s\n' "$ORDERS_PATH" "$(status_of "$response")" "$(body_of "$response")" >>"$CURRENT_LOG"
  check_eq "B6 POST /orders returns 202" 202 "$(status_of "$response")"
  check_eq "B6 the order reaches confirmed before the duplicate" confirmed \
    "$(await_status "$id" confirmed "$POLL_TIMEOUT_S")"
  wait_until "B6 the OrderFulfilled fact is published before the duplicate" \
    "$POLL_TIMEOUT_S" fulfilled_published "$id"
  published_before="$(fulfilled_published_count "$id")"
  duplicate_payload="{\"order_id\":\"$id\",\"item\":\"widget\",\"quantity\":3,\"correlation_id\":\"qual-b6-duplicate\"}"
  db_exec "INSERT INTO sol_outbox (kind, aggregate_key, ord, payload) \
    VALUES ('OrderPlaced', '$id', 1, '$duplicate_payload')"
  printf 'duplicate OrderPlaced intent injected\tkey=%s\n' "$id" >>"$CURRENT_LOG"
  wait_until "B6 the duplicate intent is relayed onto ${ORDERS_TOPIC}" \
    "$POLL_TIMEOUT_S" pending_drained "$id"
  sleep_s "${DUPLICATE_SETTLE_S:-20}"
  published_after="$(fulfilled_published_count "$id")"
  check_eq "B6 the duplicate is absorbed: one fulfilled_orders row" 1 "$(fulfilled_count "$id")"
  check_eq "B6 the duplicate is absorbed: one release_inventory job" 1 "$(jobs_count "$id" release_inventory)"
  check_eq "B6 the duplicate is absorbed: one confirmation effect" 1 "$(confirmations_count "$id")"
  check_eq "B6 the duplicate publishes no second OrderFulfilled" "$published_before" "$published_after"
  check_eq "B6 exactly one OrderFulfilled was published" 1 "$published_after"
  check_eq "B6 no pending outbox for the key" 0 "$(pending_count "$id")"
}

row_dlq() {
  local id before after dlq records raw valid
  id="$(new_order_id d5)"
  dlq="$(dlq_topic)"
  printf 'order_id\t%s\ndlq_topic\t%s\n' "$id" "$dlq" >>"$CURRENT_LOG"
  before="$(prom_sum 'sol_worker_decode_errors_total')"
  topic_produce "$ORDERS_TOPIC" "$id" 'this is not a valid OrderPlaced payload'
  printf 'undecodable record produced\ttopic=%s\tkey=%s\n' "$ORDERS_TOPIC" "$id" >>"$CURRENT_LOG"
  wait_until "D5/H1 the DLQ topic receives the raw record" "$POLL_TIMEOUT_S" dlq_has_record "$dlq"
  records="$(topic_records "$dlq")"
  raw="$(printf '%s' "$records" | grep -c 'this is not a valid OrderPlaced payload')"
  check_ge "D5/H1 the DLQ record carries the raw bytes" 1 "$raw"
  wait_until "D5/H1 sol_worker_decode_errors_total advances past $before" \
    "$POLL_TIMEOUT_S" prom_advanced 'sol_worker_decode_errors_total' "${before:-0}"
  after="$(prom_sum 'sol_worker_decode_errors_total')"
  printf 'decode errors\tbefore=%s\tafter=%s\n' "${before:-0}" "${after:-0}" >>"$CURRENT_LOG"
  valid="$(new_order_id d5-follow)"
  http_request POST "$ORDERS_PATH" "$(order_body "$valid")" >/dev/null
  check_eq "D5/H1 the source offset advanced: a later fact is still applied" confirmed \
    "$(await_status "$valid" confirmed "$POLL_TIMEOUT_S")"
}

row_h2() {
  local id1 id2
  id1="$(new_order_id h2a)"
  id2="$(new_order_id h2b)"
  printf 'order_ids\t%s\t%s\n' "$id1" "$id2" >>"$CURRENT_LOG"
  broker_scale 0
  sleep_s "$POLL_INTERVAL_S"
  http_request POST "$ORDERS_PATH" "$(order_body "$id1")" >/dev/null
  http_request POST "$ORDERS_PATH" "$(order_body "$id2")" >/dev/null
  check_eq "H2 the requests commit while the broker is unavailable" 1 "$(orders_count "$id1")"
  check_eq "H2 the requests commit while the broker is unavailable (second)" 1 "$(orders_count "$id2")"
  check_ge "H2 the outbox holds the unpublished intent" 1 "$(pending_count "$id1")"
  broker_scale 1
  restart_deploys "$ORDERS_NS" 'app.kubernetes.io/component=svc'
  restart_deploys "$FULFIL_NS" 'app.kubernetes.io/component=worker'
  wait_until "H2 the outbox drains after recovery" "$POLL_TIMEOUT_S" pending_drained "$id1"
  check_eq "H2 the outbox drains after recovery (second)" 0 "$(pending_count "$id2")"
  check_eq "H2 the recovered flow reaches confirmed" confirmed \
    "$(await_status "$id1" confirmed "$POLL_TIMEOUT_S")"
  check_eq "H2 the recovered flow reaches confirmed (second)" confirmed \
    "$(await_status "$id2" confirmed "$POLL_TIMEOUT_S")"
}

run_row() {
  local row="$1"
  mkdir -p "$LOG_DIR/rows"
  CURRENT_LOG="$LOG_DIR/rows/$row.txt"
  : >"$CURRENT_LOG"
  ROW_FAILURES=0
  row_say "row $row"
  case "$row" in
    b1) row_b1 ;;
    b2) row_b2 ;;
    b5) row_b5 ;;
    b6) row_b6 ;;
    d5 | h1) row_dlq ;;
    h2) row_h2 ;;
    *) fail_row "unknown row $row" ;;
  esac
  if [ "$ROW_FAILURES" -eq 0 ]; then
    printf 'verdict\tPASS\n' >>"$CURRENT_LOG"
    row_say "row $row: PASS"
    return 0
  fi
  printf 'verdict\tFAIL\t%s\n' "$ROW_FAILURES" >>"$CURRENT_LOG"
  row_say "row $row: FAIL ($ROW_FAILURES assertion(s))"
  return 1
}

require_tool() {
  local name="$1" value="$2"
  command -v "$value" >/dev/null 2>&1 || {
    printf 'rows-ocaml: %s=%s is not executable or not on PATH\n' "$name" "$value" >&2
    return 1
  }
}

require_tools() {
  local missing=0
  require_tool QUAL_CURL "$CURL" || missing=1
  require_tool QUAL_PSQL "$PSQL" || missing=1
  require_tool QUAL_RPK "$RPK" || missing=1
  require_tool QUAL_JQ "$JQ" || missing=1
  require_tool QUAL_KUBECTL "$KUBECTL" || missing=1
  require_tool QUAL_MD5SUM "$MD5SUM" || missing=1
  [ "$missing" -eq 0 ]
}

main() {
  case "${1:-all}" in
    -h | --help | help) usage; return 0 ;;
  esac
  [ -n "$LOG_DIR" ] || { printf 'rows-ocaml: LOG_DIR is not set\n' >&2; return 2; }
  require_tools || return 2
  mkdir -p "$LOG_DIR/rows"
  local rows=("$@")
  [ "${#rows[@]}" -eq 0 ] && rows=(b1 b2 b5 b6 d5 h2)
  if [ "${rows[0]}" = all ]; then rows=(b1 b2 b5 b6 d5 h2); fi
  local failures=0
  deploy_workspace || true
  local row
  for row in "${rows[@]}"; do
    run_row "$row" || failures=$((failures + 1))
  done
  printf 'rows-ocaml: %d/%d row(s) failed; logs under %s/rows\n' \
    "$failures" "${#rows[@]}" "$LOG_DIR"
  [ "$failures" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
