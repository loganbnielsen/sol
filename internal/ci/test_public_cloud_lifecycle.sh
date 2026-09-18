#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
guard="$root/internal/ci/check_public_cloud_lifecycle.sh"

"$guard" "$root"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/internal/qualification/aws"
printf '#!/usr/bin/env bash\nterraform apply\n' >"$tmp/internal/qualification/aws/live-smoke.sh"
if "$guard" "$tmp" >/dev/null 2>&1; then
  echo "guard accepted a qualification harness that provisions with Terraform" >&2
  exit 1
fi
