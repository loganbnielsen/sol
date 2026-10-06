#!/usr/bin/env bash
set -euo pipefail

BROKERS="${KAFKA_BROKERS:-localhost:9092}"
PARTITIONS="${TOPIC_PARTITIONS:-3}"
REPLICAS="${TOPIC_REPLICAS:-1}"

topics=(
  "sol-demo"
  "sol-producer-test"
  "sol-consumer-test"
)

json_number() {
  local field="${1:?field required}"
  local json="${2:?json required}"
  printf '%s' "$json" | sed -n "s/.*\"${field}\":\([0-9]*\).*/\1/p"
}

topic_shape() {
  local topic="${1:?topic required}"
  local json partitions replicas
  if ! json="$(rpk topic list "$topic" --brokers "$BROKERS" --format json)"; then
    return 1
  fi
  partitions="$(json_number partitions "$json")"
  replicas="$(json_number replicas "$json")"
  printf '%s %s\n' "${partitions:-0}" "${replicas:-0}"
}

for topic in "${topics[@]}"; do
  if ! shape="$(topic_shape "$topic")"; then
    echo "ERROR: could not read topic metadata from ${BROKERS}." >&2
    exit 1
  fi
  partitions="${shape%% *}"
  replicas="${shape##* }"

  if [ "$partitions" -eq 0 ]; then
    echo "Creating topic: $topic"
    if ! output="$(rpk topic create "$topic" \
      --brokers "$BROKERS" \
      --partitions "$PARTITIONS" \
      --replicas "$REPLICAS" 2>&1)"; then
      if shape="$(topic_shape "$topic")" \
         && [ "${shape%% *}" = "$PARTITIONS" ] \
         && [ "${shape##* }" = "$REPLICAS" ]; then
        echo "Topic already established: $topic"
        continue
      fi
      echo "ERROR: could not create topic '$topic' on ${BROKERS}:" >&2
      printf '%s\n' "$output" >&2
      exit 1
    fi
    printf '%s\n' "$output"
  elif [ "$partitions" = "$PARTITIONS" ] && [ "$replicas" = "$REPLICAS" ]; then
    echo "Topic already established: $topic"
  else
    echo "ERROR: required topic '$topic' exists with ${partitions} partitions and ${replicas} replicas;" >&2
    echo "       expected ${PARTITIONS} partitions and ${REPLICAS} replicas." >&2
    exit 1
  fi
done

# A create call returning success is not proof the topic was established.
# Re-read the broker's metadata and fail closed on anything absent or the wrong
# shape, so a selective ACL denial or ignored creation parameters cannot pass.
for topic in "${topics[@]}"; do
  if ! shape="$(topic_shape "$topic")"; then
    echo "ERROR: could not read topic metadata from ${BROKERS}." >&2
    exit 1
  fi
  partitions="${shape%% *}"
  replicas="${shape##* }"
  if [ "$partitions" -eq 0 ]; then
    echo "ERROR: required topic '$topic' was not established on ${BROKERS}." >&2
    exit 1
  fi
  if [ "$partitions" != "$PARTITIONS" ] || [ "$replicas" != "$REPLICAS" ]; then
    echo "ERROR: required topic '$topic' has ${partitions} partitions and ${replicas} replicas;" >&2
    echo "       expected ${PARTITIONS} partitions and ${REPLICAS} replicas." >&2
    exit 1
  fi
done

echo "Required topics established on ${BROKERS}: ${topics[*]}"
