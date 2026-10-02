#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

demo="examples/pluto/app/demo_ts"

if git diff --quiet origin/main...HEAD -- "$demo"; then
  echo "check_ts_demo: $demo is unchanged on this branch; typecheck skipped"
  exit 0
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "check_ts_demo: npm is required to typecheck the TypeScript demo" >&2
  exit 1
fi

cd "$demo"
npm ci --no-audit --no-fund
npm run build -w order-svc -w fulfillment-worker
