#!/usr/bin/env bash
# Deploy sol demo to local k3s cluster.
# Requires: k3s running, librdkafka-dev installed, dune build passing.
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

echo "=== Deploying sol to local k3s ==="

# Apply namespace first
kubectl apply -f k8s/namespace.yaml

# Deploy Redpanda
echo "Deploying Redpanda..."
kubectl apply -f k8s/redpanda.yaml
kubectl -n sol rollout status statefulset/redpanda --timeout=120s

# Build and import demo image into k3s
echo "Building sol-demo image..."
docker build -t sol-demo:local -f Dockerfile ..
echo "Importing image into k3s..."
docker save sol-demo:local | sudo k3s ctr images import -

# Deploy demo app
echo "Deploying sol-demo..."
kubectl apply -f k8s/demo-app.yaml
kubectl -n sol rollout status deployment/sol-demo --timeout=60s

echo ""
echo "=== Deployed ==="
kubectl -n sol get pods
echo ""
echo "Logs: kubectl -n sol logs -f deployment/sol-demo"
echo "Exec: kubectl -n sol exec -it deployment/sol-demo -- sh"
