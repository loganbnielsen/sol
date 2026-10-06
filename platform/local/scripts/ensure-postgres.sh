#!/usr/bin/env bash
set -euo pipefail

CONTAINER="sol-postgres"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-dev}"
POSTGRES_DB="${POSTGRES_DB:-sol_dev}"
PORT="${POSTGRES_PORT:-5432}"
IMAGE="postgres:16-alpine"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/dev-endpoints.sh"
source "${SCRIPT_DIR}/lib/readiness.sh"

if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  require_local_publish "${CONTAINER}" 5432
  echo "Postgres already running (container: ${CONTAINER})"
else
  echo "Starting Postgres..."
  dev_publish_ports "${PORT}:5432"
  docker run -d \
    --name "${CONTAINER}" \
    --rm \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    -e POSTGRES_DB="${POSTGRES_DB}" \
    "${DEV_PUBLISH_ARGS[@]}" \
    "${IMAGE}" \
    > /dev/null
fi

url="postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PORT}/${POSTGRES_DB}"
published_url="postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PORT}/${POSTGRES_DB}"
client_error="$(mktemp)"
trap 'rm -f "${client_error}"' EXIT

READINESS_TIMEOUT_S="${POSTGRES_READY_TIMEOUT_S:-60}"
READINESS_INTERVAL_S="${POSTGRES_READY_INTERVAL_S:-1}"

postgres_answers() {
  local answer status=0
  answer="$(bounded_probe "$READINESS_PROBE_TIMEOUT_S" \
    docker run --rm --network host "${IMAGE}" \
    psql "${published_url}" -tAc 'SELECT 1' 2>"${client_error}")" || status=$?
  [ "$status" = 0 ] && [ "$answer" = 1 ]
}

if wait_ready "Postgres" postgres_answers; then
  echo "Postgres ready at localhost:${PORT}"
  echo "  URL: ${url}"
  echo ""
  echo "  export POSTGRES_URL=${url}"
  exit 0
fi

echo "ERROR: Postgres did not answer a query at ${url} within ${READINESS_TIMEOUT_S}s." >&2
echo "       The container can accept connections before its server is usable; this waited for a" >&2
echo "       query to come back instead. The last client error:" >&2
tail -n 3 "${client_error}" >&2
echo "       Container ${CONTAINER}, last log lines:" >&2
docker logs --tail 20 "${CONTAINER}" >&2
exit 1
