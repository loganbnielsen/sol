#!/usr/bin/env bash

# wait_for_port PORT [MAX_ATTEMPTS] [SLEEP_SECS]
# Returns 0 when localhost:PORT accepts TCP connections; returns 1 on timeout.
wait_for_port() {
  local port="${1:?port required}"
  local max="${2:-30}"
  local delay="${3:-1}"

  for _ in $(seq 1 "$max"); do
    nc -z localhost "$port" 2>/dev/null && return 0
    sleep "$delay"
  done

  local elapsed
  elapsed="$(awk -v max="$max" -v delay="$delay" 'BEGIN { printf "%g", max * delay }')"
  echo "error: port ${port} not ready after ${elapsed}s" >&2
  return 1
}
