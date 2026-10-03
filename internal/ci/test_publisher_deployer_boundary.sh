#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
guard="$root/internal/ci/check_publisher_deployer_boundary.sh"

"$guard" "$root"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/cli/bin" "$tmp/cli/lib/cloud" "$tmp/cli/lib/deploy"
cp "$root"/cli/lib/deploy/*.ml "$tmp/cli/lib/deploy/"
cp "$root/cli/bin/cmd_deploy.ml" "$root/cli/bin/cmd_cloud.ml" \
  "$root/cli/bin/cmd_cloud_tf.ml" "$root/cli/bin/cmd_migrate.ml" "$tmp/cli/bin/"
cp "$root"/cli/lib/cloud/*.ml "$tmp/cli/lib/cloud/"

refuse_mutation() {
  local path="$1" call="$2" what="$3"
  printf '\nlet _ = Sol_cli_docker.%s\n' "$call" >>"$tmp/$path"
  if output="$("$guard" "$tmp" 2>&1)"; then
    echo "guard accepted $what ($path) that can $call images" >&2
    exit 1
  fi
  case "$output" in
    *"must not call Sol_cli_docker.build/push"*) ;;
    *)
      echo "guard refused $what ($path) for the wrong reason: $output" >&2
      exit 1
      ;;
  esac
  cp "$root/$path" "$tmp/$path"
}

refuse_mutation cli/bin/cmd_deploy.ml push "the deployer"
refuse_mutation cli/bin/cmd_migrate.ml build "the migrate path"
refuse_mutation cli/bin/cmd_cloud_tf.ml build "the provisioner"
refuse_mutation cli/lib/cloud/sol_cli_cloud_wiring.ml push "a provisioner library"
refuse_mutation cli/lib/deploy/sol_cli_deploy_run.ml push "a deployer library"
refuse_mutation cli/lib/deploy/sol_cli_migration_job.ml push "the migration Job module"

printf '\nlet _ = Sol_cli_docker.push\n' >>"$tmp/cli/lib/deploy/sol_cli_up_execution.ml"
if ! "$guard" "$tmp" >/dev/null 2>&1; then
  echo "guard refused the local sol up path (sol_cli_up_execution.ml) that builds and" \
    "pushes the workspace's own image" >&2
  exit 1
fi
cp "$root/cli/lib/deploy/sol_cli_up_execution.ml" "$tmp/cli/lib/deploy/"

rm -rf "$tmp/cli/lib/deploy"
if output="$("$guard" "$tmp" 2>&1)"; then
  echo "guard passed with no deploy sources at all, so the deploy check is vacuous" >&2
  exit 1
fi
case "$output" in
  *"would"*"pass vacuously"*) ;;
  *)
    echo "guard refused a missing deploy tree for the wrong reason: $output" >&2
    exit 1
    ;;
esac
