#!/usr/bin/env bash
set -euo pipefail

NETWORK=sol-obs
PROMETHEUS_PORT=9090
GRAFANA_PORT=3000
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/prometheus.yml"
source "${SCRIPT_DIR}/lib/images.sh"
source "${SCRIPT_DIR}/lib/dev-endpoints.sh"
source "${SCRIPT_DIR}/lib/readiness.sh"

if ! docker network inspect "$NETWORK" > /dev/null 2>&1; then
  echo "Creating Docker network: $NETWORK"
  docker network create "$NETWORK"
fi

if docker ps --format '{{.Names}}' | grep -q '^prometheus$'; then
  require_local_publish prometheus 9090
  echo "Prometheus already running"
else
  if docker ps -a --format '{{.Names}}' | grep -q '^prometheus$'; then
    echo "Restarting stopped Prometheus container..."
    docker start prometheus
    require_local_publish prometheus 9090
  else
    echo "Starting Prometheus..."
    dev_publish_ports "$PROMETHEUS_PORT:9090"
    docker run -d \
      --name prometheus \
      --network "$NETWORK" \
      "${DEV_PUBLISH_ARGS[@]}" \
      -v "${CONFIG_FILE}:/etc/prometheus/prometheus.yml:ro" \
      "$SOL_IMAGE_PROMETHEUS" \
      --config.file=/etc/prometheus/prometheus.yml \
      --storage.tsdb.path=/prometheus \
      --web.enable-lifecycle
  fi
fi

prometheus_ready() {
  http_probe "http://localhost:${PROMETHEUS_PORT}/-/healthy"
}

if ! wait_ready "Prometheus" prometheus_ready; then
  docker logs prometheus | tail -20 >&2
  exit 1
fi

if curl -sf "http://localhost:${GRAFANA_PORT}/api/health" > /dev/null 2>&1; then
  EXISTING=$(curl -sf \
    "http://localhost:${GRAFANA_PORT}/api/datasources/name/Prometheus" \
    -H "Content-Type: application/json" 2>/dev/null || echo "")

  if [ -z "$EXISTING" ]; then
    echo "Provisioning Prometheus datasource -> http://prometheus:${PROMETHEUS_PORT}"
    curl -sf -X POST \
      "http://localhost:${GRAFANA_PORT}/api/datasources" \
      -H "Content-Type: application/json" \
      -d "{
        \"name\":      \"Prometheus\",
        \"type\":      \"prometheus\",
        \"uid\":       \"prometheus\",
        \"url\":       \"http://prometheus:${PROMETHEUS_PORT}\",
        \"access\":    \"proxy\",
        \"isDefault\": false
      }" > /dev/null
    echo "Prometheus datasource provisioned"
  else
    echo "Prometheus datasource already provisioned"
  fi
else
  echo "WARNING: Grafana not running — run ensure-grafana.sh first to wire the datasource" >&2
fi

echo ""
echo "  Prometheus  -> http://localhost:${PROMETHEUS_PORT}"
echo "  Graph UI    -> http://localhost:${PROMETHEUS_PORT}/graph"
echo ""
echo "  Grafana     -> http://localhost:${GRAFANA_PORT}"
echo "  Explore     -> http://localhost:${GRAFANA_PORT}/explore  (select Prometheus datasource)"
echo ""
