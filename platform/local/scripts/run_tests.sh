#!/usr/bin/env bash
# Sol test runner — executes all test suites, enforces per-suite timeouts,
# and fails on performance regressions against a committed baseline.
#
# Usage:
#   ./platform/local/scripts/run_tests.sh                    # full run
#   ./platform/local/scripts/run_tests.sh --update-baseline  # run and record timings as new baseline
#   ./platform/local/scripts/run_tests.sh --no-infra         # skip infra setup (already running)
#   ./platform/local/scripts/run_tests.sh --reset-infra      # recreate Sol-owned local infra first
#   ./platform/local/scripts/run_tests.sh unit kafka         # run specific suites only
#
# Exit codes:
#   0  all suites passed, no regression
#   1  one or more suites failed or timed out
#   2  performance regression (exceeded per-suite threshold)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
export REPO_ROOT
BASELINE="$REPO_ROOT/tools/perf/perf_baseline.json"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
pass()  { echo -e "${GREEN}✓${NC} $*"; }
fail()  { echo -e "${RED}✗${NC} $*"; }
info()  { echo -e "${DIM}→${NC} $*"; }
header(){ echo -e "\n${BOLD}$*${NC}"; }

# ── Per-suite timeouts (seconds) ──────────────────────────────────────────────
declare -A TIMEOUTS=(
  [unit]=60
  [kafka]=120
  [e2e]=180
)

# ── Per-suite regression thresholds ──────────────────────────────────────────
# unit/e2e: 1.5× — pure OCaml or sequential workflow; only GC/scheduler noise.
# kafka: 1.4× — I/O-bound; more variance is expected.
# These replace the old single FAIL_RATIO=1.2 which produced false positives
# when infra containers ran concurrently with the unit suite.
declare -A FAIL_RATIOS=(
  [unit]=1.5
  [kafka]=1.4
  [e2e]=1.5
)

# ── Flags ────────────────────────────────────────────────────────────────────
UPDATE_BASELINE=0
SKIP_INFRA=0
RESET_INFRA=0
REQUESTED_SUITES=()

for arg in "$@"; do
  case "$arg" in
    --update-baseline) UPDATE_BASELINE=1 ;;
    --no-infra)        SKIP_INFRA=1 ;;
    --reset-infra)     RESET_INFRA=1 ;;
    unit|kafka|e2e) REQUESTED_SUITES+=("$arg") ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

ALL_SUITES=(unit kafka e2e)
SUITES=("${REQUESTED_SUITES[@]:-${ALL_SUITES[@]}}")

# ── Timing ────────────────────────────────────────────────────────────────────
now_ms()    { date +%s%3N; }
elapsed_s() { awk "BEGIN { printf \"%.3f\", ($2 - $1) / 1000 }"; }

# ── Baseline I/O (requires jq) ────────────────────────────────────────────────
HAS_JQ=0
command -v jq &>/dev/null && HAS_JQ=1

# Returns the duration_s from the most recent baseline:true entry, or "null".
baseline_get() {
  [ $HAS_JQ -eq 0 ] && echo "null" && return
  jq -r ".suites.$1.history | map(select(.baseline == true)) | last | .duration_s // \"null\"" "$BASELINE"
}

# Appends an entry to the history array. Pass baseline=true when --update-baseline.
baseline_append() {
  local suite=$1 duration_s=$2 is_baseline=$3
  [ $HAS_JQ -eq 0 ] && return
  local today; today=$(date +%Y-%m-%d)
  local commit; commit=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  local entry
  if [ "$is_baseline" = "true" ]; then
    entry="{\"date\":\"$today\",\"commit\":\"$commit\",\"duration_s\":$duration_s,\"baseline\":true}"
  else
    entry="{\"date\":\"$today\",\"commit\":\"$commit\",\"duration_s\":$duration_s}"
  fi
  local tmp; tmp=$(mktemp)
  jq ".suites.${suite}.history += [$entry]" "$BASELINE" > "$tmp"
  mv "$tmp" "$BASELINE"
}

# ── Regression check ──────────────────────────────────────────────────────────
# Pure predicate, no output — callers decide what to do with a breach.
is_regression() {
  local suite=$1 actual_s=$2
  local base; base=$(baseline_get "$suite")
  [ "$base" = "null" ] && return 1   # no baseline yet

  local ratio=${FAIL_RATIOS[$suite]}
  local threshold
  threshold=$(awk "BEGIN { printf \"%.2f\", $base * $ratio }")
  awk "BEGIN { exit !($actual_s >= $threshold) }"
}

report_regression() {
  local suite=$1 actual_s=$2
  local base; base=$(baseline_get "$suite")
  local ratio=${FAIL_RATIOS[$suite]}
  local actual_ratio; actual_ratio=$(awk "BEGIN { printf \"%.2f\", $actual_s / $base }")
  fail "$suite: ${actual_s}s vs baseline ${base}s (${actual_ratio}× — regression, threshold ${ratio}×)"
}

# ── Suite runners ─────────────────────────────────────────────────────────────
run_unit() {
  info "Primitives unit tests (no infrastructure required)"
  eval $(opam env)
  dune test --root "$REPO_ROOT" framework/ cli/sol/test/ --force 2>&1
}

run_kafka() {
  info "Kafka integration tests (requires broker at localhost:9092)"
  eval $(opam env)
  KAFKA_BROKERS=localhost:9092 dune test --root "$REPO_ROOT" integrations/kafka/ --force 2>&1
}

run_e2e() {
  info "End-to-end golden workflow tests"
  eval $(opam env)
  KAFKA_BROKERS=localhost:9092 \
  LOKI_URL=http://localhost:3100 \
  POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sol_dev \
    dune test --root "$REPO_ROOT" examples/local-demo/test/ --force 2>&1
}

# ── Infrastructure setup ──────────────────────────────────────────────────────
ensure_infra() {
  header "Infrastructure"
  local needs_kafka=0 needs_loki=0 needs_postgres=0

  for suite in "${SUITES[@]}"; do
    case "$suite" in
      kafka|e2e) needs_kafka=1; needs_loki=1; needs_postgres=1 ;;
    esac
  done

  if [ $needs_kafka    -eq 1 ]; then info "Kafka (Redpanda)";  bash "$SCRIPT_DIR/ensure-broker.sh";  fi
  if [ $needs_loki     -eq 1 ]; then info "Loki";              bash "$SCRIPT_DIR/ensure-loki.sh";    fi
  if [ $needs_postgres -eq 1 ]; then info "PostgreSQL";        bash "$SCRIPT_DIR/ensure-postgres.sh"; fi
}

reset_infra() {
  header "Reset infrastructure"
  for container in redpanda sol-postgres loki prometheus pushgateway sol-registry; do
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

# ── Result tracking ───────────────────────────────────────────────────────────
declare -A RESULTS   # suite → pass|fail|timeout
declare -A TIMINGS   # suite → elapsed seconds
REGRESSION_FAIL=0

echo -e "\n${BOLD}Sol test runner${NC}"
echo "Suites: ${SUITES[*]}"
[ $UPDATE_BASELINE -eq 1 ] && echo "Mode: --update-baseline"
[ $HAS_JQ -eq 0 ] && echo -e "${DIM}jq not found — regression checks disabled${NC}"

# Runs one attempt of $1, printing its output directly (not captured).
# Sets RUN_ONE_ELAPSED and returns the suite's exit code.
run_one() {
  local suite=$1
  local timeout_s=${TIMEOUTS[$suite]}
  local start; start=$(now_ms)
  set +e
  timeout -s KILL "$timeout_s" bash -c "$(declare -f info pass fail header now_ms elapsed_s "run_${suite}"); run_${suite}" 2>&1 \
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
  local timeout_s=${TIMEOUTS[$suite]}

  local elapsed exit_code
  # `run_one` restores `set -e` before it returns, so calling it as a bare
  # statement (`run_one ...; exit_code=$?`) would abort this whole script on
  # a non-zero return instead of letting us handle it below — wrap it as an
  # `if` condition, which bash always exempts from errexit.
  if run_one "$suite"; then exit_code=0; else exit_code=$?; fi
  elapsed=$RUN_ONE_ELAPSED
  TIMINGS[$suite]=$elapsed

  if [ $exit_code -eq 124 ] || [ $exit_code -eq 137 ]; then
    fail "${suite}: timed out after ${timeout_s}s"
    RESULTS[$suite]=timeout
    return
  elif [ $exit_code -ne 0 ]; then
    fail "${suite}: failed (${elapsed}s)"
    RESULTS[$suite]=fail
    return
  fi

  RESULTS[$suite]=pass
  pass "${suite}: passed (${elapsed}s)"

  # A single slow run can be transient contention (concurrent dune builds,
  # infra containers, etc.) rather than a real regression — see
  # CODE_LAYER-011, where this fired 4 times in one session and every time
  # an immediate manual re-run came back at baseline. Confirm with one
  # in-place re-run before flagging, the same recovery step a human
  # currently does by hand.
  if is_regression "$suite" "$elapsed"; then
    info "${suite}: ${elapsed}s exceeded threshold on first run — confirming with a re-run before flagging a regression"
    local confirm_exit
    if run_one "$suite"; then confirm_exit=0; else confirm_exit=$?; fi
    if [ $confirm_exit -eq 124 ] || [ $confirm_exit -eq 137 ]; then
      fail "${suite}: confirmation re-run timed out after ${timeout_s}s"
      RESULTS[$suite]=timeout
      TIMINGS[$suite]=$RUN_ONE_ELAPSED
      return
    elif [ $confirm_exit -ne 0 ]; then
      fail "${suite}: confirmation re-run failed (${RUN_ONE_ELAPSED}s)"
      RESULTS[$suite]=fail
      TIMINGS[$suite]=$RUN_ONE_ELAPSED
      return
    fi
    elapsed=$RUN_ONE_ELAPSED
    TIMINGS[$suite]=$elapsed
    if is_regression "$suite" "$elapsed"; then
      report_regression "$suite" "$elapsed"
      REGRESSION_FAIL=1
    else
      pass "${suite}: re-run at ${elapsed}s is within threshold — treating first run as noise"
    fi
  fi

  if [ $UPDATE_BASELINE -eq 1 ]; then
    baseline_append "$suite" "$elapsed" "true"
  else
    baseline_append "$suite" "$elapsed" "false"
  fi
}

# Run unit in isolation before starting any infrastructure.
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

# Start infrastructure only if non-unit suites are requested.
if [ ${#INFRA_SUITES[@]} -gt 0 ] && [ $SKIP_INFRA -eq 0 ]; then
  # Temporarily set SUITES to only infra suites for ensure_infra's needs check.
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

# ── Summary table ─────────────────────────────────────────────────────────────
header "Summary"
printf "  %-18s %-10s %-10s %-12s %-8s\n" "Suite" "Result" "Time" "Baseline" "Threshold"
printf "  %-18s %-10s %-10s %-12s %-8s\n" "─────────────────" "──────────" "─────────" "────────────" "─────────"

ALL_PASSED=1
for suite in "${ALL_SUITES[@]}"; do
  [[ " ${SUITES[*]} " =~ " ${suite} " ]] || continue

  result=${RESULTS[$suite]}
  elapsed=${TIMINGS[$suite]}
  base=$(baseline_get "$suite")
  threshold=${FAIL_RATIOS[$suite]}

  case "$result" in
    pass)    result_str="${GREEN}pass${NC}" ;;
    fail)    result_str="${RED}fail${NC}";    ALL_PASSED=0 ;;
    timeout) result_str="${RED}timeout${NC}"; ALL_PASSED=0 ;;
  esac

  [ "$base" = "null" ] && base_str="${DIM}none${NC}" || base_str="${base}s"

  printf "  %-18s " "$suite"
  echo -ne "$result_str"
  printf "%-$((10 - ${#result} + 6))s" ""
  printf "%-10s" "${elapsed}s"
  printf "%-14s" "$base_str"
  echo "${threshold}×"
done

if [ $UPDATE_BASELINE -eq 1 ]; then
  echo ""
  pass "Baseline entries recorded in $BASELINE"
fi

# ── Exit ──────────────────────────────────────────────────────────────────────
echo ""
if [ $ALL_PASSED -eq 0 ]; then
  fail "One or more suites failed."
  exit 1
elif [ $REGRESSION_FAIL -eq 1 ]; then
  fail "Performance regression detected (exceeded per-suite threshold)."
  exit 2
else
  pass "All suites passed."
  exit 0
fi
