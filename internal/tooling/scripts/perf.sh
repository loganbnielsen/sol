#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BASELINE="$REPO_ROOT/internal/tooling/perf/perf_baseline.json"

ALL_SUITES=(unit kafka observability storage e2e)
RECORDABLE_SUITES=(unit kafka postgres e2e)

declare -A FAIL_RATIOS=(
  [unit]=1.5
  [kafka]=1.4
  [observability]=1.4
  [storage]=1.4
  [e2e]=1.5
)

RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

command -v jq &>/dev/null || { echo "perf.sh requires jq (sudo apt-get install jq)"; exit 1; }

host_class() { uname -srm 2>/dev/null | tr ' ' '-'; }

short_host() {
  local host=$1
  if [ ${#host} -le 24 ]; then echo "$host"; else echo "${host:0:21}..."; fi
}

suite_baseline()      { jq -r "(.suites.$1.history // []) | map(select(.baseline==true)) | last | .duration_s // \"null\"" "$BASELINE"; }
suite_baseline_host() { jq -r "(.suites.$1.history // []) | map(select(.baseline==true)) | last | .host // \"null\"" "$BASELINE"; }
suite_latest()        { jq -r "(.suites.$1.history // []) | last | .duration_s // \"null\"" "$BASELINE"; }
suite_latest_host()   { jq -r "(.suites.$1.history // []) | last | .host // \"null\"" "$BASELINE"; }
suite_count()         { jq -r "(.suites.$1.history // []) | length" "$BASELINE"; }

drift_pct() {
  local base=$1 val=$2
  [ "$base" = "null" ] || [ "$val" = "null" ] && echo "—" && return
  awk "BEGIN { d=($val-$base)/$base*100; printf \"%+.0f%%\", d }"
}

is_regression() {
  local suite=$1 base=$2 val=$3
  [ "$base" = "null" ] || [ "$val" = "null" ] && return 1
  local ratio=${FAIL_RATIOS[$suite]}
  awk "BEGIN { exit !($val / $base >= $ratio) }"
}

comparable() {
  local base=$1 latest=$2 base_host=$3 latest_host=$4
  [ "$base" = "null" ] && return 1
  [ "$latest" = "null" ] && return 1
  [ "$base_host" = "null" ] && return 1
  [ "$base_host" = "$latest_host" ]
}

cmd_status() {
  local regressions_only=0
  [ "${1:-}" = "--regressions-only" ] && regressions_only=1

  local rows=() breached=0 incomparable=()
  local header_main header_rule
  header_main="$(
    printf "  ${BOLD}%-16s %-18s %-11s %-11s %-9s %-8s %s${NC}" \
      "Suite" "Host" "Baseline" "Latest" "Drift" "Thresh" "Runs"
  )"
  header_rule="$(
    printf "  %-16s %-18s %-11s %-11s %-9s %-8s %s" \
      "───────────────" "─────────────────" "──────────" "──────────" "────────" "───────" "────"
  )"

  for suite in "${ALL_SUITES[@]}"; do
    local base; base=$(suite_baseline "$suite")
    local latest; latest=$(suite_latest "$suite")
    local base_host; base_host=$(suite_baseline_host "$suite")
    local latest_host; latest_host=$(suite_latest_host "$suite")
    local count; count=$(suite_count "$suite")
    local threshold="${FAIL_RATIOS[$suite]}×"

    local base_s="—";   [ "$base"   != "null" ] && base_s="${base}s"
    local latest_s="—"; [ "$latest" != "null" ] && latest_s="${latest}s"
    local host_s="—";   [ "$latest_host" != "null" ] && host_s="$(short_host "$latest_host")"

    local drift_cell
    local drift
    if comparable "$base" "$latest" "$base_host" "$latest_host"; then
      drift=$(drift_pct "$base" "$latest")
      if is_regression "$suite" "$base" "$latest"; then
        breached=1
        drift_cell="${RED}${drift}${NC}"
      else
        drift_cell="$drift"
      fi
    else
      drift="n/a"
      drift_cell="${DIM}n/a${NC}"
      if [ "$base" != "null" ] || [ "$latest" != "null" ]; then
        incomparable+=("$suite: baseline host ${base_host}, latest host ${latest_host}")
      fi
    fi

    rows+=(
      "$(
        printf "  %-16s %-18s %-11s %-11s " "$suite" "$host_s" "$base_s" "$latest_s"
        printf "%b" "$drift_cell"
        printf " %*s" $((9 - ${#drift} + ${#threshold})) "$threshold"
        printf " %s" "$count"
      )"
    )
  done

  if [ "$regressions_only" = "1" ] && [ "$breached" = "0" ]; then
    return 0
  fi

  echo ""
  printf '%s\n' "$header_main" "$header_rule" "${rows[@]}"
  if [ ${#incomparable[@]} -gt 0 ]; then
    echo ""
    echo -e "  ${DIM}not comparable within one host class (record on the same host to compare):${NC}"
    for note in "${incomparable[@]}"; do
      echo -e "    ${DIM}${note}${NC}"
    done
  fi
  echo ""
}

cmd_history() {
  local target="${1:-}"
  local suites=("${ALL_SUITES[@]}")
  [ -n "$target" ] && suites=("$target")

  for suite in "${suites[@]}"; do
    local count; count=$(suite_count "$suite")
    local base; base=$(suite_baseline "$suite")
    local base_host; base_host=$(suite_baseline_host "$suite")
    local base_s="none"; [ "$base" != "null" ] && base_s="${base}s"
    local threshold="${FAIL_RATIOS[$suite]}×"

    echo -e "\n  ${BOLD}${suite}${NC} — ${count} run(s), baseline: ${base_s} on ${base_host}, threshold: ${threshold}"

    if [ "$count" -eq 0 ]; then
      echo -e "  ${DIM}no data yet — run: internal/tooling/scripts/perf.sh record ${suite}${NC}"
      continue
    fi

    local idx=0
    local total; total=$(suite_count "$suite")
    while IFS=$'\t' read -r date commit host duration is_baseline; do
      idx=$((idx + 1))
      local suffix=""
      local color="$NC"

      [ "$is_baseline" = "true" ] && suffix=" ${DIM}● baseline${NC}"
      [ "$idx" -eq "$total" ]     && suffix="${suffix} ${DIM}← latest${NC}"

      if [ "$is_baseline" != "true" ] && comparable "$base" "$duration" "$base_host" "$host" && is_regression "$suite" "$base" "$duration"; then
        color="$RED"
        local ratio; ratio=$(awk "BEGIN { printf \"%.2f\", $duration / $base }")
        suffix=" ${RED}✗ regression (${ratio}×, threshold ${FAIL_RATIOS[$suite]}×)${NC}"
      fi

      echo -e "  ${color}${date}   ${commit}   ${host}   ${duration}s${NC}${suffix}"
    done < <(jq -r "(.suites.${suite}.history // [])[] | [.date, (.commit // \"—\"), (.host // \"—\"), .duration_s, (.baseline // false)] | @tsv" "$BASELINE")
  done
  echo ""
}

mark_latest_baseline() {
  local suite=$1
  local tmp; tmp=$(mktemp)
  jq ".suites.${suite}.history |= (map(del(.baseline)) | .[-1].baseline = true)" \
    "$BASELINE" > "$tmp"
  mv "$tmp" "$BASELINE"
}

now_ms() { date +%s%3N; }

cmd_record() {
  local update_baseline=0
  local requested=()
  for arg in "$@"; do
    case "$arg" in
      --update-baseline) update_baseline=1 ;;
      unit|kafka|e2e)    requested+=("$arg") ;;
      *)
        echo "perf.sh record: expected --update-baseline or a suite in: ${RECORDABLE_SUITES[*]} (got '$arg')" >&2
        exit 1
        ;;
    esac
  done

  local suites=("${requested[@]:-${RECORDABLE_SUITES[@]}}")
  local host; host=$(host_class)
  local today; today=$(date +%Y-%m-%d)
  local commit; commit=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")

  for suite in "${suites[@]}"; do
    local start; start=$(now_ms)
    local rc=0
    bash "$REPO_ROOT/internal/tooling/scripts/run_tests.sh" "$suite" || rc=$?
    local end; end=$(now_ms)
    local duration; duration=$(awk "BEGIN { printf \"%.3f\", ($end - $start) / 1000 }")

    if [ $rc -ne 0 ]; then
      echo -e "  ${RED}✗${NC} ${suite}: run_tests.sh exited ${rc}; not recorded (a failed run is not a performance datum)"
      continue
    fi

    local base; base=$(suite_baseline "$suite")
    local base_host; base_host=$(suite_baseline_host "$suite")
    if comparable "$base" "$duration" "$base_host" "$host"; then
      local drift; drift=$(drift_pct "$base" "$duration")
      if is_regression "$suite" "$base" "$duration"; then
        echo -e "  ${RED}✗${NC} ${suite}: ${duration}s vs baseline ${base}s on ${host} (${drift}, threshold ${FAIL_RATIOS[$suite]}×) — informational"
      else
        echo -e "  ${GREEN}✓${NC} ${suite}: ${duration}s vs baseline ${base}s on ${host} (${drift})"
      fi
    else
      echo -e "  ${DIM}${suite}: ${duration}s on ${host}; no same-host baseline to compare (baseline host ${base_host})${NC}"
    fi

    if [ $update_baseline -eq 1 ]; then
      local tmp; tmp=$(mktemp)
      jq --arg suite "$suite" --arg date "$today" --arg commit "$commit" --arg host "$host" \
        --argjson duration "$duration" \
        '.suites[$suite] = ((.suites[$suite] // {}) | .history = ((.history // []) + [{date: $date, commit: $commit, host: $host, duration_s: $duration, baseline: false}]))' \
        "$BASELINE" > "$tmp"
      mv "$tmp" "$BASELINE"
      mark_latest_baseline "$suite"
      echo -e "  ${GREEN}✓${NC} ${suite}: ${duration}s recorded as the new baseline on ${host}"
    fi
  done
}

cmd_set_baseline() {
  local target="${1:-all}"
  local suites=("${ALL_SUITES[@]}")
  [ "$target" != "all" ] && suites=("$target")

  for suite in "${suites[@]}"; do
    local count; count=$(suite_count "$suite")
    if [ "$count" -eq 0 ]; then
      echo -e "  ${DIM}${suite}: no runs recorded — run: internal/tooling/scripts/perf.sh record ${suite}${NC}"
      continue
    fi

    mark_latest_baseline "$suite"

    local latest; latest=$(suite_latest "$suite")
    echo -e "  ${GREEN}✓${NC} ${suite}: baseline set to ${latest}s"
  done
}

cmd_clear() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    echo "Usage: perf.sh clear <suite|all>"
    exit 1
  fi

  local suites=("${ALL_SUITES[@]}")
  [ "$target" != "all" ] && suites=("$target")

  for suite in "${suites[@]}"; do
    local tmp; tmp=$(mktemp)
    jq ".suites.${suite}.history = []" "$BASELINE" > "$tmp"
    mv "$tmp" "$BASELINE"
    echo -e "  ${GREEN}✓${NC} ${suite}: history cleared"
  done
}

cmd="${1:-status}"
shift || true

case "$cmd" in
  status)       cmd_status "$@" ;;
  history)      cmd_history "$@" ;;
  record)       cmd_record "$@" ;;
  set-baseline) cmd_set_baseline "$@" ;;
  clear)        cmd_clear "$@" ;;
  *)
    echo "Usage: perf.sh <status|history|record|set-baseline|clear> [suite|all] [--update-baseline]"
    echo "Suites: ${ALL_SUITES[*]} (recordable: ${RECORDABLE_SUITES[*]})"
    exit 1 ;;
esac
