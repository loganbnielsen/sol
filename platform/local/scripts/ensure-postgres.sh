#!/usr/bin/env bash
set -euo pipefail

CONTAINER="sol-postgres"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-dev}"
POSTGRES_DB="${POSTGRES_DB:-sol_dev}"
PORT="${POSTGRES_PORT:-5432}"
IMAGE="postgres:16-alpine"
READY_TIMEOUT="${POSTGRES_READY_TIMEOUT_S:-60}"
READY_INTERVAL="${POSTGRES_READY_INTERVAL_S:-1}"

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
    "${IMAGE}" \
    > /dev/null
fi

url="postgresql://postgres:${POSTGRES_PASSWORD}@localhost:${PORT}/${POSTGRES_DB}"
published_url="postgresql://postgres:${POSTGRES_PASSWORD}@host.docker.internal:${PORT}/${POSTGRES_DB}"
client_error="$(mktemp)"
trap 'rm -f "${client_error}"' EXIT

postgres_answers() {
  local answer status=0
  answer="$(docker run --rm --add-host host.docker.internal:host-gateway "${IMAGE}" \
    psql "${published_url}" -tAc 'SELECT 1' 2>"${client_error}")" || status=$?
  [ "$status" = 0 ] && [ "$answer" = 1 ]
}

echo -n "Waiting up to ${READY_TIMEOUT}s for a query at localhost:${PORT} "
deadline=$((SECONDS + READY_TIMEOUT))
while [ "$SECONDS" -lt "$deadline" ]; do
  if postgres_answers; then
    echo "ready."
    echo "Postgres ready at localhost:${PORT}"
    echo "  URL: ${url}"
    echo ""
    echo "  export POSTGRES_URL=${url}"
    exit 0
  fi
  echo -n "."
  sleep "${READY_INTERVAL}"
done

echo ""
echo "ERROR: Postgres did not answer a query at ${url} within ${READY_TIMEOUT}s." >&2
echo "       The container can accept connections before its server is usable; this waited for a" >&2
echo "       query to come back instead. The last client error:" >&2
tail -n 3 "${client_error}" >&2
echo "       Container ${CONTAINER}, last log lines:" >&2
docker logs --tail 20 "${CONTAINER}" >&2
exit 1
