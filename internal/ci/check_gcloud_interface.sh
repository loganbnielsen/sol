#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
source_file="$root/cli/lib/cloud/sol_cli_gcp_cluster.ml"
subcommand="container clusters get-credentials"

fail=0
report() {
  echo "check_gcloud_interface: $1" >&2
  fail=1
}

if ! grep -q 'gcp_provisioner_kubeconfig' "$source_file"; then
  report "the GCP cluster-access function Sol uses is gone; this check is now vacuous"
fi
gcp_access_fn="$(sed -n '/^let gcp_provisioner_kubeconfig/,/^let gcp_cloud_ready/p' "$source_file")"
if [ -z "$gcp_access_fn" ]; then
  report "could not extract the GCP cluster-access function for inspection"
fi
for flag in --kubeconfig; do
  case "$gcp_access_fn" in
    *"\"$flag\""*) report "Sol passes $flag to \`$subcommand\`, which does not accept it (Attempt 2)" ;;
  esac
done
case "$gcp_access_fn" in
  *'provisioner_kube_env path'*) ;;
  *) report "the GCP access call no longer exports its own KUBECONFIG" ;;
esac

gcp_root="$root/platform/cloud/gcp/cluster"
if ! grep -qE 'service_account_id = google_service_account\.provisioner\.name' \
  "$gcp_root"/*.tf; then
  report "the impersonation grant is not scoped to the provisioner service account itself"
fi
if ! grep -qE 'role[[:space:]]*=[[:space:]]*"roles/iam\.serviceAccountTokenCreator"' \
  "$gcp_root"/*.tf; then
  report "the impersonation grant does not use roles/iam.serviceAccountTokenCreator"
fi
if grep -qE 'role[[:space:]]*=[[:space:]]*"roles/(owner|editor|iam\.serviceAccountAdmin)"' \
  "$gcp_root"/*.tf; then
  report "the GCP root grants a broad project role to the install identities"
fi
if ! grep -qE 'member[[:space:]]*=[[:space:]]*each\.value' "$gcp_root"/*.tf; then
  report "the impersonation grant's members are not the caller the target declared"
fi
if ! grep -qE 'variable "provisioner_impersonators"' "$gcp_root"/*.tf; then
  report "the GCP root does not declare provisioner_impersonators; the caller cannot be declared"
fi
gcp_keys="$(sed -n '/^  | Gcp ->/,/^  | [A-Z]/p' "$root/cli/lib/base/sol_cli_provider.ml")"
case "$gcp_keys" in
  *'"provisioner_impersonator"'*) ;;
  *) report "Sol's provider tier does not assign provisioner_impersonator to the gcp block (Sol_cli_provider.owned_keys)" ;;
esac
if ! grep -q 'provider_field target "provisioner_impersonator"' \
  "$root/cli/lib/cloud/sol_cli_provider_capabilities.ml"; then
  report "the GCP capabilities do not read the target's provisioner_impersonator"
fi

argv_checked=0
if command -v gcloud >/dev/null 2>&1; then
  argv_checked=1
  flags=(--region --project --impersonate-service-account --quiet)
  set +e
  raw_help="$(gcloud $subcommand --help 2>&1)"
  help_status=$?
  set -e
  help_text="$(printf '%s' "$raw_help" | sed 's/\x1b\[[0-9;]*m//g')"
  help_preview="$(
    printf '%s\n' "$help_text" | grep -v '^[[:space:]]*$' | sed -n '1,3p' | tr '\n' '|'
  )" || true
  help_is_usable() {
    [[ "$help_text" == *"$subcommand"* ]] || return 1
    local upper="${help_text^^}"
    [[ "$upper" == *SYNOPSIS* || "$upper" == *USAGE* ]]
  }
  if [ "$help_status" -ne 0 ] || [ -z "$help_text" ] || ! help_is_usable; then
    report "gcloud's \`$subcommand --help\` produced no usable help (exit $help_status), so Sol's argv could not be validated against the real CLI; first lines: ${help_preview:-<none>}"
  else
    flag_documented() {
      local pattern="(^|[^-[:alnum:]])$1([^-[:alnum:]]|$)"
      [[ "$help_text" =~ $pattern ]]
    }
    for flag in "${flags[@]}"; do
      if ! flag_documented "$flag"; then
        report "gcloud's \`$subcommand\` does not document $flag, but Sol passes it"
      fi
    done
    if flag_documented --kubeconfig; then
      report "--kubeconfig now exists on \`$subcommand\`; revisit whether Sol should use it"
    fi
  fi
elif [ "${CHECK_GCLOUD_INTERFACE_ALLOW_MISSING_GCLOUD:-0}" = "1" ]; then
  echo "check_gcloud_interface: gcloud is not installed, so Sol's argv was not validated against the real CLI (explicitly opted out by CHECK_GCLOUD_INTERFACE_ALLOW_MISSING_GCLOUD=1); the static install-authority checks ran." >&2
else
  report "gcloud is not installed, so Sol's argv could not be validated against the real CLI; install gcloud, or set CHECK_GCLOUD_INTERFACE_ALLOW_MISSING_GCLOUD=1 to opt out explicitly"
fi

[ "$fail" -eq 0 ] || exit 1
if [ "$argv_checked" = 1 ]; then
  echo "check_gcloud_interface: Sol's GCP cluster-access argv matches the real gcloud interface; the impersonation grant is scoped to the named identity and the declared caller."
else
  echo "check_gcloud_interface: the install-authority checks passed; the gcloud interface was not validated (explicit opt-out)."
fi
