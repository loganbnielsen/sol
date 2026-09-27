#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/wait-port.sh"

"${SCRIPT_DIR}/start-redpanda.sh"

KAFKA_PORT="${KAFKA_PORT:-9092}"
echo -n "Waiting for port ${KAFKA_PORT}"
wait_for_port "${KAFKA_PORT}" 20 1 || { echo ""; exit 1; }
echo " ready."

"${SCRIPT_DIR}/create-topics.sh"
