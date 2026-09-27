#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(git rev-parse --show-toplevel)}"

if grep -Eq 'Sol_cli_docker\.(build|push)' \
  "$root/cli/bin/cmd_cloud.ml" "$root/cli/bin/cmd_cloud_tf.ml" "$root"/cli/lib/cloud/*.ml
then
  echo "the provisioner (cmd_cloud[_tf].ml, cli/lib/cloud) must not call" \
    "Sol_cli_docker.build/push" >&2
  exit 1
fi

if grep -Eq 'Sol_cli_docker\.(build|push)' "$root/cli/bin/cmd_deploy.ml" \
  "$root/cli/lib/deploy/sol_cli_deploy_selection.ml" \
  "$root/cli/lib/deploy/sol_cli_deploy_run.ml"
then
  echo "the deployer (cmd_deploy.ml, sol_cli_deploy_{selection,run}.ml) must not call" \
    "Sol_cli_docker.build/push -- it may" \
    "only inspect/resolve a digest via manifest_exists/inspect_digest" >&2
  exit 1
fi
