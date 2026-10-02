#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
export REPO_ROOT

RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
pass()  { echo -e "${GREEN}✓${NC} $*"; }
fail()  { echo -e "${RED}✗${NC} $*"; }
info()  { echo -e "${DIM}→${NC} $*"; }
header(){ echo -e "\n${BOLD}$*${NC}"; }

declare -A HANG_BOUNDS=(
  [unit]=300
  [kafka]=900
  [e2e]=1200
)

SKIP_INFRA=0
RESET_INFRA=0
REQUESTED_SUITES=()

for arg in "$@"; do
  case "$arg" in
    --no-infra)    SKIP_INFRA=1 ;;
    --reset-infra) RESET_INFRA=1 ;;
    unit|kafka|e2e) REQUESTED_SUITES+=("$arg") ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

ALL_SUITES=(unit kafka e2e)
SUITES=("${REQUESTED_SUITES[@]:-${ALL_SUITES[@]}}")

now_ms()    { date +%s%3N; }
elapsed_s() { awk "BEGIN { printf \"%.3f\", ($2 - $1) / 1000 }"; }

run_unit() {
  info "Primitives unit tests (no infrastructure required)"
  eval $(opam env)
  dune test --root "$REPO_ROOT" framework/ocaml/sol-env/ framework/ocaml/sol-fn/ framework/ocaml/sol-obs/ framework/ocaml/sol-svc/ framework/ocaml/sol-worker/ cli/test/ --force 2>&1
}

run_kafka() {
  info "Kafka integration tests (requires broker at localhost:9092)"
  eval $(opam env)
  dune build --root "$REPO_ROOT" @framework/ocaml/kafka-eio-service/test/runtest-integration 2>&1
}

run_e2e() {
  info "End-to-end golden workflow tests"
  eval $(opam env)
  dune build --root "$REPO_ROOT" @internal/fixtures/local-demo/test/runtest 2>&1
}

ensure_infra() {
  header "Infrastructure"
  local needs_kafka=0 needs_loki=0 needs_postgres=0

  for suite in "${SUITES[@]}"; do
    case "$suite" in
      kafka|e2e) needs_kafka=1; needs_loki=1; needs_postgres=1 ;;
    esac
  done

  if [ $needs_kafka    -eq 1 ]; then info "Kafka (Redpanda)";  bash "$REPO_ROOT/platform/local/scripts/ensure-broker.sh";  fi
  if [ $needs_loki     -eq 1 ]; then info "Loki";              bash "$REPO_ROOT/platform/local/scripts/ensure-loki.sh";    fi
  if [ $needs_postgres -eq 1 ]; then info "PostgreSQL";        bash "$REPO_ROOT/platform/local/scripts/ensure-postgres.sh"; fi
}

reset_infra() {
  header "Reset infrastructure"
  for container in redpanda sol-postgres loki prometheus pushgateway grafana tempo sol-registry; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
      info "Removing container: ${container}"
      docker rm -f "${container}" >/dev/null
    fi
  done
  if command -v k3d >/dev/null 2>&1 && k3d cluster list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -q '^sol-local$'; then
    info "Deleting k3d cluster: sol-local"
    k3d cluster delete sol-local >/dev/null
  fi
}

declare -A RESULTS
declare -A TIMINGS

echo -e "\n${BOLD}Sol correctness runner${NC}"
echo "Suites: ${SUITES[*]}"
echo "Hang bounds (a suite killed at its bound is a hang, not a slow pass): unit=${HANG_BOUNDS[unit]}s kafka=${HANG_BOUNDS[kafka]}s e2e=${HANG_BOUNDS[e2e]}s"

run_one() {
  local suite=$1
  local bound=${HANG_BOUNDS[$suite]}
  local start; start=$(now_ms)
  set +e
  timeout -s KILL "$bound" bash -c "$(declare -f info pass fail header now_ms elapsed_s "run_${suite}"); run_${suite}" 2>&1 \
    | sed 's/^/    /'
  local exit_code=${PIPESTATUS[0]}
  set -e
  local end; end=$(now_ms)
  RUN_ONE_ELAPSED=$(elapsed_s "$start" "$end")
  return $exit_code
}

run_suite() {
  local suite=$1
  echo -e "\n  ${BOLD}${suite}${NC}"
  local bound=${HANG_BOUNDS[$suite]}

  local elapsed exit_code
  if run_one "$suite"; then exit_code=0; else exit_code=$?; fi
  elapsed=$RUN_ONE_ELAPSED
  TIMINGS[$suite]=$elapsed

  if [ $exit_code -eq 124 ] || [ $exit_code -eq 137 ]; then
    fail "${suite}: hang — killed after the ${bound}s hang bound"
    RESULTS[$suite]=hang
    return
  elif [ $exit_code -ne 0 ]; then
    fail "${suite}: failed (${elapsed}s)"
    RESULTS[$suite]=fail
    return
  fi

  RESULTS[$suite]=pass
  pass "${suite}: passed (${elapsed}s)"
}

INFRA_SUITES=()
UNIT_REQUESTED=0
for suite in "${SUITES[@]}"; do
  if [ "$suite" = "unit" ]; then
    UNIT_REQUESTED=1
  else
    INFRA_SUITES+=("$suite")
  fi
done

if [ $UNIT_REQUESTED -eq 1 ]; then
  header "Suites (unit — pre-infra)"
  run_suite unit
fi

if [ ${#INFRA_SUITES[@]} -gt 0 ] && [ $SKIP_INFRA -eq 0 ]; then
  SUITES=("${INFRA_SUITES[@]}")
  if [ $RESET_INFRA -eq 1 ]; then
    reset_infra
  fi
  ensure_infra
  SUITES=("${REQUESTED_SUITES[@]:-${ALL_SUITES[@]}}")
fi

if [ ${#INFRA_SUITES[@]} -gt 0 ]; then
  header "Suites (infra-dependent)"
  for suite in "${INFRA_SUITES[@]}"; do
    run_suite "$suite"
  done
fi

header "Summary"
printf "  %-10s %-8s %-12s %s\n" "Suite" "Result" "Time" "Hang bound"
printf "  %-10s %-8s %-12s %s\n" "──────────" "────────" "────────────" "──────────"

ALL_PASSED=1
for suite in "${ALL_SUITES[@]}"; do
  [[ " ${SUITES[*]} " =~ " ${suite} " ]] || continue

  result=${RESULTS[$suite]}
  elapsed=${TIMINGS[$suite]}

  case "$result" in
    pass) result_str="${GREEN}pass${NC}" ;;
    fail) result_str="${RED}fail${NC}"; ALL_PASSED=0 ;;
    hang) result_str="${RED}hang${NC}"; ALL_PASSED=0 ;;
  esac

  printf "  %-10s " "$suite"
  printf "%b" "$result_str"
  printf "%*s" $((8 - ${#result})) ""
  printf "%-12s" "${elapsed}s"
  printf "%ss\n" "${HANG_BOUNDS[$suite]}"
done

echo ""
if [ $ALL_PASSED -eq 0 ]; then
  fail "One or more suites failed or hung."
  exit 1
else
  pass "All suites passed."
  exit 0
fi
