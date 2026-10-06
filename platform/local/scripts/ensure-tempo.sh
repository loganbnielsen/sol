#!/usr/bin/env bash
set -euo pipefail

OTLP_PORT=4318
QUERY_PORT=3200
NETWORK=sol-obs
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/tempo.yaml"
source "${SCRIPT_DIR}/lib/port-preflight.sh"
source "${SCRIPT_DIR}/lib/images.sh"
source "${SCRIPT_DIR}/lib/dev-endpoints.sh"
source "${SCRIPT_DIR}/lib/readiness.sh"

check_port_forward_conflict "$OTLP_PORT" tempo
check_port_forward_conflict "$QUERY_PORT" tempo

if ! docker network inspect "$NETWORK" > /dev/null 2>&1; then
  echo "Creating Docker network: $NETWORK"
  docker network create "$NETWORK"
fi

if docker ps --format '{{.Names}}' | grep -q '^tempo$'; then
  require_local_publish tempo 4318
  require_local_publish tempo 3200
  echo "Tempo already running"
else
  if docker ps -a --format '{{.Names}}' | grep -q '^tempo$'; then
    require_local_publish tempo 4318
    require_local_publish tempo 3200
    echo "Restarting stopped Tempo container..."
    docker start tempo
  else
    echo "Starting Tempo..."
    dev_publish_ports "$OTLP_PORT:4318" "$QUERY_PORT:3200"
    docker run -d \
      --name tempo \
      --network "$NETWORK" \
      "${DEV_PUBLISH_ARGS[@]}" \
      -v "${CONFIG_FILE}:/etc/tempo.yaml:ro" \
      "$SOL_IMAGE_TEMPO" \
      -config.file=/etc/tempo.yaml
  fi
fi

tempo_ready() {
  http_probe "http://localhost:${QUERY_PORT}/ready"
}

if ! wait_ready "Tempo" tempo_ready; then
  docker logs tempo | tail -20 >&2
  exit 1
fi

if ! docker network inspect "$NETWORK" \
     --format '{{range .Containers}}{{.Name}} {{end}}' \
     | grep -qw tempo; then
  echo "Connecting tempo to $NETWORK"
  docker network connect "$NETWORK" tempo
fi

echo ""
echo "  OTLP/HTTP ingestion -> http://localhost:${OTLP_PORT}  (obs-tempo-eio's TEMPO_URL)"
echo "  Query API           -> http://localhost:${QUERY_PORT} (obs-tempo-eio's TEMPO_QUERY_URL)"
echo ""
