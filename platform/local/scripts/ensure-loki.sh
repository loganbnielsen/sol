#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/port-preflight.sh"

check_port_forward_conflict 3100 loki

if docker ps --format '{{.Names}}' | grep -q '^loki$'; then
  echo "Loki already running"
else
  if docker ps -a --format '{{.Names}}' | grep -q '^loki$'; then
    echo "Restarting stopped Loki container..."
    docker start loki
  else
    echo "Starting Loki..."
    docker run -d \
      --name loki \
      -p 3100:3100 \
      grafana/loki:3.0.0 \
      -config.file=/etc/loki/local-config.yaml
  fi

  echo -n "Waiting for Loki to be ready"
  for i in $(seq 1 30); do
    if curl -sf http://localhost:3100/ready > /dev/null 2>&1; then
      echo " ready"
      exit 0
    fi
    sleep 1
    echo -n "."
  done
  echo ""
  echo "ERROR: Loki did not become ready within 30s" >&2
  docker logs loki | tail -20 >&2
  exit 1
fi
