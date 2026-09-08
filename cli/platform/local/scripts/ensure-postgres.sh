#!/usr/bin/env bash
set -euo pipefail

CONTAINER="sol-postgres"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-dev}"
POSTGRES_DB="${POSTGRES_DB:-sol_dev}"
PORT="${POSTGRES_PORT:-5432}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/wait-port.sh"

if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "Postgres already running (container: ${CONTAINER})"
else
  echo "Starting Postgres..."
  docker run -d \
    --name "${CONTAINER}" \
    --rm \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    -e POSTGRES_DB="${POSTGRES_DB}" \
    -p "${PORT}:5432" \
    postgres:16-alpine \
    > /dev/null
fi

echo "Waiting for port ${PORT} ready."
wait_for_port "${PORT}" 30 0.5 || exit 1

# Wait for Postgres to accept connections
for i in $(seq 1 20); do
  if docker exec "${CONTAINER}" pg_isready -q 2>/dev/null; then break; fi
  sleep 0.5
done

echo "Postgres ready at localhost:${PORT}"
echo "  URL: postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PORT}/${POSTGRES_DB}"
echo ""
echo "  export POSTGRES_URL=postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PORT}/${POSTGRES_DB}"
