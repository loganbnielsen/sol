#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(git rev-parse --show-toplevel)}"
smoke="$root/devtools/aws-live-smoke.sh"

if sed '/^[[:space:]]*#/d' "$smoke" | grep -Eq '(^|[[:space:]])(terraform|helm)([[:space:]]|$)'; then
  echo "aws-live-smoke.sh must not invoke Terraform or Helm" >&2
  exit 1
fi
