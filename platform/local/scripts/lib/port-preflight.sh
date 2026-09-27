#!/usr/bin/env bash

check_port_forward_conflict() {
  local port="${1:?port required}"
  local service="${2:?service name required}"

  local match
  match="$(ps -eo pid,args 2>/dev/null \
             | grep -E 'kubectl( .*)? port-forward' \
             | grep -E "([^0-9]|^)${port}:" || true)"

  if [ -n "$match" ]; then
    echo "" >&2
    echo "ERROR: a 'kubectl port-forward' is already bound to port ${port}." >&2
    echo "It will silently shadow the local ${service} container: on Linux a" >&2
    echo "127.0.0.1:${port} listener wins over 0.0.0.0:${port} for localhost" >&2
    echo "traffic, so every request to localhost:${port} would reach whatever" >&2
    echo "cluster that port-forward points at instead of this local ${service}." >&2
    echo "Kill it first:" >&2
    echo "" >&2
    echo "$match" | sed 's/^/    /' >&2
    echo "" >&2
    return 1
  fi
}
