#!/usr/bin/env bash
# Sets up a local Redpanda broker for development/testing on WSL2 (Ubuntu).
# No Docker required — installs the native Redpanda binary via apt.
set -euo pipefail

echo "=== Sol local dev setup ==="

# ---- librdkafka (OCaml FFI dependency) ----
if ! dpkg -l librdkafka-dev &>/dev/null; then
  echo "Installing librdkafka-dev..."
  sudo apt-get update -qq
  sudo apt-get install -y librdkafka-dev
else
  echo "librdkafka-dev already installed."
fi

# ---- Redpanda ----
if ! command -v rpk &>/dev/null; then
  echo "Installing Redpanda..."
  curl -1sLf \
    'https://dl.redpanda.com/nzc4OSAS3Po1HzbFEFR4/redpanda/cfg/setup/bash.deb.sh' \
    | sudo -E bash
  sudo apt-get install -y redpanda
else
  echo "Redpanda already installed ($(rpk version))."
fi

# ---- k3s (local Kubernetes) ----
if ! command -v k3s &>/dev/null; then
  echo "Installing k3s..."
  curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
  echo "Waiting for k3s to be ready..."
  sudo k3s kubectl wait --for=condition=Ready node --all --timeout=120s
else
  echo "k3s already installed."
fi

echo ""
echo "=== Setup complete ==="
echo "Start Redpanda:  rpk redpanda start --overprovisioned --smp 1 --memory 512M"
echo "Stop Redpanda:   rpk redpanda stop"
echo "Broker address:  localhost:9092"
echo ""
echo "Build OCaml:     cd kafka && dune build"
echo "Run unit tests:  cd kafka && dune test"
echo "Run demo:        cd kafka && KAFKA_BROKERS=localhost:9092 dune exec demo/bin/demo.exe"
