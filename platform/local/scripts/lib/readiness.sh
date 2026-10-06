#!/usr/bin/env bash
# Shared bounded-readiness policy for the local service setup helpers.
#
# One wall-clock deadline, one probe per attempt, and a hard per-attempt
# command bound. A helper supplies only its service-specific probe; this
# policy decides whether setup succeeded. Nothing here prints a success
# claim until a probe has actually succeeded.

READINESS_TIMEOUT_S="${READINESS_TIMEOUT_S:-30}"
READINESS_INTERVAL_S="${READINESS_INTERVAL_S:-1}"
READINESS_PROBE_TIMEOUT_S="${READINESS_PROBE_TIMEOUT_S:-2}"
READINESS_CONNECT_TIMEOUT_S="${READINESS_CONNECT_TIMEOUT_S:-2}"

# bounded_probe <seconds> <command...>
#
# Run one probe under a hard wall-clock bound so a hung probe cannot stall the
# readiness loop. Falls back to the command's own bound when `timeout` is
# unavailable.
bounded_probe() {
  local seconds="${1:?probe bound required}"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=1 "${seconds}s" "$@"
  else
    "$@"
  fi
}

# http_probe <url>
#
# HTTP readiness probe with explicit per-request connect and total bounds.
http_probe() {
  bounded_probe "$READINESS_PROBE_TIMEOUT_S" \
    curl --silent --show-error --fail \
      --connect-timeout "$READINESS_CONNECT_TIMEOUT_S" \
      --max-time "$READINESS_PROBE_TIMEOUT_S" \
      "$1"
}

# wait_ready <label> <probe>
#
# Run <probe> until it succeeds or the overall deadline passes. Prints a ready
# line and returns 0 only after a probe succeeds. On exhaustion prints the last
# failed observation to stderr and returns nonzero, so no caller can claim
# success for infrastructure that never became usable.
wait_ready() {
  local label="${1:?label required}"
  local probe="${2:?probe required}"
  local start="$SECONDS"
  local deadline=$((start + READINESS_TIMEOUT_S))
  local observation=""
  printf 'Waiting for %s' "$label"
  while :; do
    if observation="$("$probe" 2>&1)"; then
      printf ' — ready\n'
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      break
    fi
    printf '.'
    sleep "$READINESS_INTERVAL_S"
  done
  printf '\n'
  echo "ERROR: ${label} was not ready within ${READINESS_TIMEOUT_S}s." >&2
  if [ -n "$observation" ]; then
    printf '%s\n' "$observation" | tail -n 5 | sed 's/^/  /' >&2
  fi
  return 1
}
