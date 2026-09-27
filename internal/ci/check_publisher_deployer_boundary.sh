#!/usr/bin/env bash
set -euo pipefail

# ADR 0002 / INFRA-022 identity table: provisioner may reconcile substrate but
# must not publish or replace application artifacts; deployer consumes an
# already-published, immutable digest and must not build or push. For a
# single CLI binary with no separate runtime privilege boundary, the call
# graph *is* the effective permission -- a capability that is never invoked
# from a code path cannot be exercised from it, so grepping for the call
# itself is real evidence here, not policy-text grep.

root="${1:-$(git rev-parse --show-toplevel)}"

# The provisioner is the `sol cloud` commands and the cloud library they drive
# (REFAC-139 moved the lifecycle wiring into cli/lib/cloud).
if grep -Eq 'Sol_cli_docker\.(build|push)' \
  "$root/cli/bin/cmd_cloud.ml" "$root/cli/bin/cmd_cloud_tf.ml" "$root"/cli/lib/cloud/*.ml
then
  echo "the provisioner (cmd_cloud[_tf].ml, cli/lib/cloud) must not call" \
    "Sol_cli_docker.build/push" >&2
  exit 1
fi

if grep -Eq 'Sol_cli_docker\.(build|push)' "$root/cli/bin/cmd_deploy.ml"; then
  echo "cmd_deploy.ml (deployer) must not call Sol_cli_docker.build/push -- it may" \
    "only inspect/resolve a digest via manifest_exists/inspect_digest" >&2
  exit 1
fi
