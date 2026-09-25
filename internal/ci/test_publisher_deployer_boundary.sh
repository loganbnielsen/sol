#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
guard="$root/internal/ci/check_publisher_deployer_boundary.sh"

# Today's repo must pass.
"$guard" "$root"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/cli/bin"
cp "$root/cli/bin/cmd_deploy.ml" "$root/cli/bin/cmd_cloud.ml" \
  "$root/cli/bin/cmd_cloud_tf.ml" "$tmp/cli/bin/"

# A deployer that could push would let deploying an existing digest also
# replace it.
printf '\nlet _ = Sol_cli_docker.push\n' >>"$tmp/cli/bin/cmd_deploy.ml"
if "$guard" "$tmp" >/dev/null 2>&1; then
  echo "guard accepted a deployer (cmd_deploy.ml) that can push images" >&2
  exit 1
fi
cp "$root/cli/bin/cmd_deploy.ml" "$tmp/cli/bin/cmd_deploy.ml"

# A provisioner that could build/push would subsume the publisher.
printf '\nlet _ = Sol_cli_docker.build\n' >>"$tmp/cli/bin/cmd_cloud_tf.ml"
if "$guard" "$tmp" >/dev/null 2>&1; then
  echo "guard accepted a provisioner (cmd_cloud_tf.ml) that can build images" >&2
  exit 1
fi
