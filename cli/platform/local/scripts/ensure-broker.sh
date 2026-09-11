#!/usr/bin/env bash
# Ensure Redpanda is running and all test topics exist.
# Called automatically before integration tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/wait-port.sh"

"${SCRIPT_DIR}/start-redpanda.sh"

# Verify the host-side port is accepting connections before creating topics.
# start-redpanda.sh checks internal cluster health via rpk inside the container,
# but the host port binding can lag behind — and the already-running fast-path
# exits immediately with no checks at all.
KAFKA_PORT="${KAFKA_PORT:-9092}"
echo -n "Waiting for port ${KAFKA_PORT}"
wait_for_port "${KAFKA_PORT}" 20 1 || { echo ""; exit 1; }
echo " ready."

"${SCRIPT_DIR}/create-topics.sh"
