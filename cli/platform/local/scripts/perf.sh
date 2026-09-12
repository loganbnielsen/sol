#!/usr/bin/env bash
# Sol performance baseline tool.
#
# Usage:
#   cli/platform/local/scripts/perf.sh status                  # all suites at a glance
#   cli/platform/local/scripts/perf.sh history [suite]         # run history per suite
#   cli/platform/local/scripts/perf.sh set-baseline [suite|all] # mark latest run as new baseline
#   cli/platform/local/scripts/perf.sh clear [suite|all]        # wipe history

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
BASELINE="$REPO_ROOT/devtools/perf/perf_baseline.json"

ALL_SUITES=(unit kafka observability storage e2e)

# ── Per-suite regression thresholds (mirrors run_tests.sh) ───────────────────
declare -A FAIL_RATIOS=(
  [unit]=1.5
  [kafka]=1.4
  [observability]=1.4
  [storage]=1.4
  [e2e]=1.5
)

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

command -v jq &>/dev/null || { echo "perf.sh requires jq (sudo apt-get install jq)"; exit 1; }

# ── Data accessors ────────────────────────────────────────────────────────────
# `history` can be absent/null for suites that have never been recorded in
# perf_baseline.json (e.g. observability/storage before their first run).
# `// []` keeps every accessor total even when a suite key is missing.
suite_baseline() { jq -r "(.suites.$1.history // []) | map(select(.baseline==true)) | last | .duration_s // \"null\"" "$BASELINE"; }
suite_latest()   { jq -r "(.suites.$1.history // []) | last | .duration_s // \"null\"" "$BASELINE"; }
suite_count()    { jq -r "(.suites.$1.history // []) | length" "$BASELINE"; }

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

# ── status ────────────────────────────────────────────────────────────────────
# Renders the status table. With [--regressions-only] it prints nothing unless a
# suite has crossed its threshold — the post-commit hook uses that mode, because
# a signal that fires on every commit is noise, and the gate that actually fails
# a breached suite lives in pre-commit (REFAC-085). Called without a flag, the
# output is unchanged.
cmd_status() {
  local regressions_only=0
  [ "${1:-}" = "--regressions-only" ] && regressions_only=1

  # Rows are collected rather than printed, because "say nothing when clean" can
  # only be decided once every suite has been measured.
  local rows=() breached=0
  local header_main header_rule
  header_main="$(
    printf "  ${BOLD}%-16s %-11s %-11s %-9s %-8s %s${NC}" \
      "Suite" "Baseline" "Latest" "Drift" "Thresh" "Runs"
  )"
  header_rule="$(
    printf "  %-16s %-11s %-11s %-9s %-8s %s" \
      "───────────────" "──────────" "──────────" "────────" "───────" "────"
  )"

  for suite in "${ALL_SUITES[@]}"; do
    local base; base=$(suite_baseline "$suite")
    local latest; latest=$(suite_latest "$suite")
    local count; count=$(suite_count "$suite")
    local drift; drift=$(drift_pct "$base" "$latest")
    local threshold="${FAIL_RATIOS[$suite]}×"

    local base_s="—";   [ "$base"   != "null" ] && base_s="${base}s"
    local latest_s="—"; [ "$latest" != "null" ] && latest_s="${latest}s"

    local drift_cell
    if is_regression "$suite" "$base" "$latest"; then
      breached=1
      drift_cell="${RED}${drift}${NC}"
    else
      drift_cell="$drift"
    fi
    # Same printf sequence as before, built into one string so the column
    # alignment is untouched by the refactor.
    rows+=(
      "$(
        printf "  %-16s %-11s %-11s " "$suite" "$base_s" "$latest_s"
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
  echo ""
}

# ── history ───────────────────────────────────────────────────────────────────
cmd_history() {
  local target="${1:-}"
  local suites=("${ALL_SUITES[@]}")
  [ -n "$target" ] && suites=("$target")

  for suite in "${suites[@]}"; do
    local count; count=$(suite_count "$suite")
    local base; base=$(suite_baseline "$suite")
    local base_s="none"; [ "$base" != "null" ] && base_s="${base}s"
    local threshold="${FAIL_RATIOS[$suite]}×"

    echo -e "\n  ${BOLD}${suite}${NC} — ${count} run(s), baseline: ${base_s}, threshold: ${threshold}"

    if [ "$count" -eq 0 ]; then
      echo -e "  ${DIM}no data yet — run: cli/platform/local/scripts/run_tests.sh ${suite}${NC}"
      continue
    fi

    local idx=0
    local total; total=$(suite_count "$suite")
    while IFS=$'\t' read -r date commit duration is_baseline; do
      idx=$((idx + 1))
      local suffix=""
      local color="$NC"

      [ "$is_baseline" = "true" ] && suffix=" ${DIM}● baseline${NC}"
      [ "$idx" -eq "$total" ]     && suffix="${suffix} ${DIM}← latest${NC}"

      if [ "$is_baseline" != "true" ] && is_regression "$suite" "$base" "$duration"; then
        color="$RED"
        local ratio; ratio=$(awk "BEGIN { printf \"%.2f\", $duration / $base }")
        suffix=" ${RED}✗ regression (${ratio}×, threshold ${FAIL_RATIOS[$suite]}×)${NC}"
      fi

      echo -e "  ${color}${date}   ${commit}   ${duration}s${NC}${suffix}"
    done < <(jq -r "(.suites.${suite}.history // [])[] | [.date, (.commit // \"—\"), .duration_s, (.baseline // false)] | @tsv" "$BASELINE")
  done
  echo ""
}

# ── set-baseline ──────────────────────────────────────────────────────────────
cmd_set_baseline() {
  local target="${1:-all}"
  local suites=("${ALL_SUITES[@]}")
  [ "$target" != "all" ] && suites=("$target")

  for suite in "${suites[@]}"; do
    local count; count=$(suite_count "$suite")
    if [ "$count" -eq 0 ]; then
      echo -e "  ${DIM}${suite}: no runs recorded — run tests first${NC}"
      continue
    fi

    local tmp; tmp=$(mktemp)
    # Remove baseline flag from all entries, then mark the last one.
    jq ".suites.${suite}.history |= (map(del(.baseline)) | .[-1].baseline = true)" \
      "$BASELINE" > "$tmp"
    mv "$tmp" "$BASELINE"

    local latest; latest=$(suite_latest "$suite")
    echo -e "  ${GREEN}✓${NC} ${suite}: baseline set to ${latest}s"
  done
}

# ── clear ─────────────────────────────────────────────────────────────────────
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

# ── dispatch ──────────────────────────────────────────────────────────────────
cmd="${1:-status}"
shift || true

case "$cmd" in
  status)       cmd_status "$@" ;;
  history)      cmd_history "$@" ;;
  set-baseline) cmd_set_baseline "$@" ;;
  clear)        cmd_clear "$@" ;;
  *)
    echo "Usage: perf.sh <status|history|set-baseline|clear> [suite|all]"
    echo "Suites: ${ALL_SUITES[*]}"
    exit 1 ;;
esac
