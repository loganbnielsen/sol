#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(git rev-parse --show-toplevel)}"

collect() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -name '*.ml' | sort
}

require_sources() {
  local what="$1" count="$2"
  if [ "$count" -lt 1 ]; then
    echo "check_publisher_deployer_boundary: no $what sources found, so its check would" \
      "pass vacuously -- fix the path it searches" >&2
    exit 1
  fi
}

cloud_libs=()
while IFS= read -r f; do cloud_libs+=("$f"); done < <(collect "$root/cli/lib/cloud")
deploy_libs=()
while IFS= read -r f; do
  case "$(basename "$f")" in
    sol_cli_up_*.ml) continue ;;
  esac
  deploy_libs+=("$f")
done < <(collect "$root/cli/lib/deploy")

require_sources "cli/lib/cloud" "${#cloud_libs[@]}"
require_sources "deploy-path cli/lib/deploy" "${#deploy_libs[@]}"

refuse() {
  local what="$1"
  shift
  if grep -Eq 'Sol_cli_docker\.(build|push)' "$@"; then
    echo "the $what must not call Sol_cli_docker.build/push. Sol resolves a" \
      "digest read-only (manifest_exists/inspect_digest): publishing belongs to the" \
      "publisher identity outside Sol (ADR 0002), and the migration runner is" \
      "published by the release process and consumed by digest (SEC-011)." >&2
    return 1
  fi
}

refuse "provisioner (cmd_destroy.ml, cmd_target.ml, cmd_cloud_tf.ml, cli/lib/cloud)" \
  "$root/cli/bin/cmd_destroy.ml" "$root/cli/bin/cmd_target.ml" "$root/cli/bin/cmd_cloud_tf.ml" \
  "${cloud_libs[@]}" \
  || exit 1
refuse "deploy path (cmd_deploy.ml, cmd_migrate.ml, cli/lib/deploy)" \
  "$root/cli/bin/cmd_deploy.ml" "$root/cli/bin/cmd_migrate.ml" "${deploy_libs[@]}" \
  || exit 1
