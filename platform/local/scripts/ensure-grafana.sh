#!/usr/bin/env bash
set -euo pipefail

NETWORK=sun-obs
LOKI_URL=http://loki:3100
TEMPO_URL=http://tempo:3200
GRAFANA_PORT=3000
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_PROVIDER_FILE="$SCRIPT_DIR/../config/grafana-dashboards.yml"
DASHBOARD_DIR="$SCRIPT_DIR/../config/grafana-dashboards"
source "${SCRIPT_DIR}/lib/port-preflight.sh"

check_port_forward_conflict "$GRAFANA_PORT" grafana

# ------------------------------------------------------------------ #
# Shared Docker network                                               #
# ------------------------------------------------------------------ #

if ! docker network inspect "$NETWORK" > /dev/null 2>&1; then
  echo "Creating Docker network: $NETWORK"
  docker network create "$NETWORK"
fi

# Connect Loki to the shared network if it's running but not yet on it.
if docker ps --format '{{.Names}}' | grep -q '^loki$'; then
  if ! docker network inspect "$NETWORK" \
       --format '{{range .Containers}}{{.Name}} {{end}}' \
       | grep -qw loki; then
    echo "Connecting loki to $NETWORK"
    docker network connect "$NETWORK" loki
  fi
else
  echo "WARNING: Loki container is not running — run ensure-loki.sh first" >&2
fi

if docker ps --format '{{.Names}}' | grep -q '^tempo$'; then
  if ! docker network inspect "$NETWORK" \
       --format '{{range .Containers}}{{.Name}} {{end}}' \
       | grep -qw tempo; then
    echo "Connecting tempo to $NETWORK"
    docker network connect "$NETWORK" tempo
  fi
else
  echo "WARNING: Tempo container is not running — run ensure-tempo.sh first for trace lookup" >&2
fi

# ------------------------------------------------------------------ #
# Grafana                                                             #
# ------------------------------------------------------------------ #

if docker ps --format '{{.Names}}' | grep -q '^grafana$'; then
  echo "Grafana already running at http://localhost:${GRAFANA_PORT}"
else
  if docker ps -a --format '{{.Names}}' | grep -q '^grafana$'; then
    echo "Restarting stopped Grafana container..."
    docker start grafana
  else
    echo "Starting Grafana..."
    docker run -d \
      --name grafana \
      --network "$NETWORK" \
      -p "${GRAFANA_PORT}:3000" \
      -e GF_AUTH_ANONYMOUS_ENABLED=true \
      -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin \
      -e GF_AUTH_DISABLE_LOGIN_FORM=true \
      -v "${DASHBOARD_PROVIDER_FILE}:/etc/grafana/provisioning/dashboards/sun-demo.yml:ro" \
      -v "${DASHBOARD_DIR}:/etc/grafana/dashboards:ro" \
      grafana/grafana:11.3.0
  fi

  echo -n "Waiting for Grafana to be ready"
  for i in $(seq 1 30); do
    if curl -sf "http://localhost:${GRAFANA_PORT}/api/health" > /dev/null 2>&1; then
      echo " ready"
      break
    fi
    sleep 1
    echo -n "."
  done
  echo ""
fi

# ------------------------------------------------------------------ #
# Provision datasources (idempotent)                                  #
# ------------------------------------------------------------------ #

upsert_datasource () {
  local name="$1"
  local payload="$2"
  local existing uid

  existing=$(curl -sf "http://localhost:${GRAFANA_PORT}/api/datasources/name/${name}" \
               -H "Content-Type: application/json" 2>/dev/null || echo "")
  if [ -z "$existing" ]; then
    echo "Provisioning ${name} datasource"
    curl -sf -X POST \
      "http://localhost:${GRAFANA_PORT}/api/datasources" \
      -H "Content-Type: application/json" \
      -d "$payload" > /dev/null
  else
    uid=$(printf '%s' "$existing" | sed -n 's/.*"uid":"\([^"]*\)".*/\1/p')
    echo "Updating ${name} datasource"
    curl -sf -X PUT \
      "http://localhost:${GRAFANA_PORT}/api/datasources/uid/${uid}" \
      -H "Content-Type: application/json" \
      -d "$payload" > /dev/null
  fi
}

upsert_datasource "Loki" "{
  \"name\": \"Loki\",
  \"type\": \"loki\",
  \"uid\": \"loki\",
  \"url\": \"${LOKI_URL}\",
  \"access\": \"proxy\",
  \"isDefault\": true,
  \"jsonData\": {
    \"derivedFields\": [{
      \"datasourceUid\": \"tempo\",
      \"matcherRegex\": \"trace_id=([0-9a-f]{32})\",
      \"name\": \"TraceID\",
      \"url\": \"\${__value.raw}\"
    }]
  }
}"

upsert_datasource "Tempo" "{
  \"name\": \"Tempo\",
  \"type\": \"tempo\",
  \"uid\": \"tempo\",
  \"url\": \"${TEMPO_URL}\",
  \"access\": \"proxy\",
  \"isDefault\": false
}"

echo "Datasources provisioned"

echo ""
echo "  Grafana  -> http://localhost:${GRAFANA_PORT}"
echo "  Explore  -> http://localhost:${GRAFANA_PORT}/explore"
echo "  Query    -> {service=\"<your-service>\"}"
echo ""
