#!/usr/bin/env bash
set -euo pipefail

BROKERS="${KAFKA_BROKERS:-localhost:9092}"

topics=(
  "sol-demo"
  "sol-producer-test"
  "sol-consumer-test"
)

for topic in "${topics[@]}"; do
  echo "Creating topic: $topic"
  rpk topic create "$topic" \
    --brokers "$BROKERS" \
    --partitions 3 \
    --replicas 1 \
    2>&1 | grep -v "TOPIC_ALREADY_EXISTS" || true
done

echo "Topics:"
rpk topic list --brokers "$BROKERS"
