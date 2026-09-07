#!/usr/bin/env bash

# check_port_forward_conflict PORT SERVICE_NAME
#
# Fails loudly, naming the conflicting process, if a `kubectl port-forward`
# is already bound to PORT. On Linux, a listener on 127.0.0.1:PORT wins over
# one on 0.0.0.0:PORT for localhost/127.0.0.1 traffic, so a leftover
# port-forward from `sun dev up` (which forwards these same conventional
# ports to the real k3d cluster) silently shadows the ensure-*.sh container
# this script is about to start: the container starts fine, but every local
# curl/test talks to the real cluster instead and produces confusing
# errors that look like real bugs. See BUG-008.
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
