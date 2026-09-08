#!/usr/bin/env bash
set -euo pipefail

NETWORK=sol-obs
PROMETHEUS_PORT=9090
GRAFANA_PORT=3000
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/prometheus.yml"

if ! docker network inspect "$NETWORK" > /dev/null 2>&1; then
  echo "Creating Docker network: $NETWORK"
  docker network create "$NETWORK"
fi

# ------------------------------------------------------------------ #
# Prometheus                                                          #
# ------------------------------------------------------------------ #

if docker ps --format '{{.Names}}' | grep -q '^prometheus$'; then
  echo "Prometheus already running at http://localhost:${PROMETHEUS_PORT}"
else
  if docker ps -a --format '{{.Names}}' | grep -q '^prometheus$'; then
    echo "Restarting stopped Prometheus container..."
    docker start prometheus
  else
    echo "Starting Prometheus..."
    docker run -d \
      --name prometheus \
      --network "$NETWORK" \
      -p "${PROMETHEUS_PORT}:9090" \
      -v "${CONFIG_FILE}:/etc/prometheus/prometheus.yml:ro" \
      prom/prometheus:latest \
      --config.file=/etc/prometheus/prometheus.yml \
      --storage.tsdb.path=/prometheus \
      --web.enable-lifecycle
  fi

  echo -n "Waiting for Prometheus to be ready"
  for i in $(seq 1 30); do
    if curl -sf "http://localhost:${PROMETHEUS_PORT}/-/healthy" > /dev/null 2>&1; then
      echo " ready"
      break
    fi
    sleep 1
    echo -n "."
  done
  echo ""
fi

# ------------------------------------------------------------------ #
# Provision Prometheus datasource in Grafana (idempotent)            #
# ------------------------------------------------------------------ #

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
