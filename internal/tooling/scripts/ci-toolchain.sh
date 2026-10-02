#!/usr/bin/env bash
set -euo pipefail

K3D_VERSION="v5.6.0"
HELM_VERSION="v3.21.0"
KUBECTL_VERSION="v1.29.0"

DEST="${SOL_TOOLCHAIN_DEST:-/usr/local/bin}"

place() {
  local src="$1" name="$2"
  chmod +x "$src"
  if [ -w "$DEST" ]; then
    mv "$src" "$DEST/$name"
  else
    sudo mv "$src" "$DEST/$name"
  fi
}

install_k3d() {
  mkdir -p "$DEST"
  curl -fsSL -o /tmp/sol-ci-toolchain-k3d \
    "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-amd64"
  place /tmp/sol-ci-toolchain-k3d k3d
}

install_helm() {
  mkdir -p "$DEST"
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C /tmp
  place /tmp/linux-amd64/helm helm
}

install_kubectl() {
  mkdir -p "$DEST"
  curl -fsSL -o /tmp/sol-ci-toolchain-kubectl \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  place /tmp/sol-ci-toolchain-kubectl kubectl
  kubectl version --client
}

case "${1:-all}" in
  all)
    install_k3d
    install_helm
    install_kubectl
    ;;
  kubectl)
    install_kubectl
    ;;
  *)
    echo "usage: ci-toolchain.sh [all|kubectl]" >&2
    exit 2
    ;;
esac
