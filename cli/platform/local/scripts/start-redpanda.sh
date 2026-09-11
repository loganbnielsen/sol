#!/usr/bin/env bash
# Start a single-node Redpanda broker for local development using Docker.
# Idempotent: safe to run if Redpanda is already up.
# Exposes: 9092 (Kafka), 9644 (admin), 8081 (schema registry)
set -euo pipefail

CONTAINER="redpanda"
KAFKA_PORT="${KAFKA_PORT:-9092}"
ADMIN_PORT="${ADMIN_PORT:-9644}"
SCHEMA_REGISTRY_PORT="${SCHEMA_REGISTRY_PORT:-8081}"

# Already running — nothing to do.
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "Redpanda already running (container: ${CONTAINER})"
  exit 0
fi

# Stopped container with the same name — remove it first.
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "Removing stopped container: ${CONTAINER}"
  docker rm "${CONTAINER}"
fi

echo "Starting Redpanda..."
docker run -d --name "${CONTAINER}" \
  -p "${KAFKA_PORT}:9092" \
  -p "${ADMIN_PORT}:9644" \
  -p "${SCHEMA_REGISTRY_PORT}:8081" \
  docker.redpanda.com/redpandadata/redpanda:latest \
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

echo -n "Waiting for broker"
for i in $(seq 1 30); do
  if docker exec "${CONTAINER}" rpk cluster health --watch=false > /dev/null 2>&1; then
    echo " ready."
    exit 0
  fi
  echo -n "."
  sleep 1
done

echo ""
echo "ERROR: Redpanda did not become ready within 30 seconds." >&2
docker logs --tail 20 "${CONTAINER}" >&2
exit 1
