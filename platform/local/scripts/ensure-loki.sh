#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/port-preflight.sh"
source "${SCRIPT_DIR}/lib/dev-endpoints.sh"
source "${SCRIPT_DIR}/lib/readiness.sh"

check_port_forward_conflict 3100 loki

if docker ps --format '{{.Names}}' | grep -q '^loki$'; then
  require_local_publish loki 3100
  echo "Loki already running"
else
  if docker ps -a --format '{{.Names}}' | grep -q '^loki$'; then
    require_local_publish loki 3100
    echo "Restarting stopped Loki container..."
    docker start loki
  else
    echo "Starting Loki..."
    dev_publish_ports "3100:3100"
    docker run -d \
      --name loki \
      "${DEV_PUBLISH_ARGS[@]}" \
      grafana/loki:3.0.0 \
      -config.file=/etc/loki/local-config.yaml
  fi
fi

loki_ready() {
  http_probe "http://localhost:3100/ready"
}

if ! wait_ready "Loki" loki_ready; then
  docker logs loki | tail -20 >&2
  exit 1
fi
