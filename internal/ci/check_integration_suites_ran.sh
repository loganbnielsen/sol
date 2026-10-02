#!/usr/bin/env bash
set -euo pipefail

jobs_group="claim by kind (BUG-044 a)"
outbox_group="composition"
success_marker="Test Successful"

usage() {
  echo "usage: check_integration_suites_ran.sh <suite-log>..." >&2
  echo "" >&2
  echo "Each log is the captured output of one database-backed suite run from" >&2
  echo "the integration step. The step passes only when the log shows that suite" >&2
  echo "reporting success with its database group executed: a run served from" >&2
  echo "dune's cache leaves the log empty, so an empty log is a failed step." >&2
}

fail() {
  echo "check_integration_suites_ran: $*" >&2
  exit 1
}

strip_ansi() {
  sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g'
}

ran_group() {
  local text="$1" group="$2"
  grep -F '[OK]' <<<"$text" | grep -qF "$group"
}

if [ "$#" -eq 0 ]; then
  usage
  exit 1
fi

for log in "$@"; do
  [ -f "$log" ] || fail "no such log: $log"
  text="$(strip_ansi <"$log")"
  case "$(basename "$log")" in
    *jobs*) want="$jobs_group" ;;
    *outbox*) want="$outbox_group" ;;
    *) fail "$log names no suite this check knows: expected 'jobs' or 'outbox' in the file name" ;;
  esac
  if ! grep -qF "$success_marker" <<<"$text"; then
    fail "$log does not report '$success_marker'; the suite was served from cache rather than executed"
  fi
  if ! ran_group "$text" "$want"; then
    fail "$log does not show the database group '$want' as [OK]; the suite did not run its database cases"
  fi
done

echo "check_integration_suites_ran: $# log(s) show their database cases executed"
