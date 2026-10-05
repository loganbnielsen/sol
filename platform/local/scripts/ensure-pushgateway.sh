#!/usr/bin/env bash
set -euo pipefail

NETWORK=sol-obs
PUSHGATEWAY_PORT=9091
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/images.sh"
source "${SCRIPT_DIR}/lib/dev-endpoints.sh"

if ! docker network inspect "$NETWORK" > /dev/null 2>&1; then
  echo "Creating Docker network: $NETWORK"
  docker network create "$NETWORK"
fi

if docker ps --format '{{.Names}}' | grep -q '^pushgateway$'; then
  require_local_publish pushgateway 9091
  echo "Pushgateway already running at http://localhost:${PUSHGATEWAY_PORT}"
else
  if docker ps -a --format '{{.Names}}' | grep -q '^pushgateway$'; then
    echo "Restarting stopped Pushgateway container..."
    docker start pushgateway
    require_local_publish pushgateway 9091
  else
    echo "Starting Pushgateway..."
    dev_publish_ports "$PUSHGATEWAY_PORT:9091"
    docker run -d \
      --name pushgateway \
      --network "$NETWORK" \
      "${DEV_PUBLISH_ARGS[@]}" \
      "$SOL_IMAGE_PUSHGATEWAY"
  fi

  echo -n "Waiting for Pushgateway to be ready"
  for i in $(seq 1 20); do
    if curl -sf "http://localhost:${PUSHGATEWAY_PORT}/-/healthy" > /dev/null 2>&1; then
      echo " ready"
      break
    fi
    sleep 1
    echo -n "."
  done
  echo ""
fi

echo "  Pushgateway -> http://localhost:${PUSHGATEWAY_PORT}"
echo "  Metrics UI  -> http://localhost:${PUSHGATEWAY_PORT}/#"
echo ""
