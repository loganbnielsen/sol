#!/usr/bin/env bash
set -euo pipefail

CONTAINER="redpanda"
KAFKA_PORT="${KAFKA_PORT:-9092}"
ADMIN_PORT="${ADMIN_PORT:-9644}"
SCHEMA_REGISTRY_PORT="${SCHEMA_REGISTRY_PORT:-8081}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/images.sh"
source "${SCRIPT_DIR}/lib/dev-endpoints.sh"
source "${SCRIPT_DIR}/lib/readiness.sh"

if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  require_local_publish "${CONTAINER}" 9092
  require_local_publish "${CONTAINER}" 9644
  require_local_publish "${CONTAINER}" 8081
  echo "Redpanda already running (container: ${CONTAINER})"
  exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "Removing stopped container: ${CONTAINER}"
  docker rm "${CONTAINER}"
fi

echo "Starting Redpanda..."
dev_publish_ports "${KAFKA_PORT}:9092" "${ADMIN_PORT}:9644" "${SCHEMA_REGISTRY_PORT}:8081"
docker run -d --name "${CONTAINER}" \
  "${DEV_PUBLISH_ARGS[@]}" \
  "$SOL_IMAGE_REDPANDA" \
  redpanda start \
  --overprovisioned \
  --smp 1 \
  --memory 512M \
  --reserve-memory 0M \
  --node-id 0 \
  --check=false \
  --kafka-addr 0.0.0.0:9092 \
  --advertise-kafka-addr "localhost:${KAFKA_PORT}" \
  --schema-registry-addr 0.0.0.0:8081 \
  > /dev/null

redpanda_ready() {
  bounded_probe "$READINESS_PROBE_TIMEOUT_S" \
    docker exec "${CONTAINER}" rpk cluster health --watch=false
}

if ! wait_ready "broker" redpanda_ready; then
  docker logs --tail 20 "${CONTAINER}" >&2
  exit 1
fi
