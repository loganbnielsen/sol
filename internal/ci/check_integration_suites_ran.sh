#!/usr/bin/env bash
set -euo pipefail

jobs_case="another workspace's rows are never"
outbox_case="the outbox and sol-jobs share one"

usage() {
  echo "usage: check_integration_suites_ran.sh <suite-log>..." >&2
  echo "" >&2
  echo "Each log is the captured output of one database-backed suite run from" >&2
  echo "the integration step. The step passes only when the log shows the" >&2
  echo "suite's Postgres-backed case actually ran: a run served from dune's" >&2
  echo "cache leaves the log without it." >&2
}

fail() {
  echo "check_integration_suites_ran: $*" >&2
  exit 1
}

strip_ansi() {
  sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g'
}

ran_ok() {
  local text="$1" needle="$2"
  grep -F '[OK]' <<<"$text" | grep -qF "$needle"
}

if [ "$#" -eq 0 ]; then
  usage
  exit 1
fi

for log in "$@"; do
  [ -f "$log" ] || fail "no such log: $log"
  text="$(strip_ansi <"$log")"
  case "$(basename "$log")" in
    *jobs*) want="$jobs_case" ;;
    *outbox*) want="$outbox_case" ;;
    *) fail "$log names no suite this check knows: expected 'jobs' or 'outbox' in the file name" ;;
  esac
  if ! ran_ok "$text" "$want"; then
    fail "$log does not show '$want' as [OK]; the suite was served from cache rather than executed"
  fi
done

echo "check_integration_suites_ran: $# log(s) show their database cases executed"
