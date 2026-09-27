#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
source_file="$root/cli/lib/cloud/sol_cli_gcp_cluster.ml"

fail=0
report() {
  echo "check_gcloud_interface: $1" >&2
  fail=1
}

if ! command -v gcloud >/dev/null 2>&1; then
  echo "check_gcloud_interface: SKIPPED -- gcloud is not installed, so the real CLI interface could not be validated. Sol's gcloud argv is unverified here."
  exit 0
fi

subcommand="container clusters get-credentials"
flags=(--region --project --impersonate-service-account --quiet)

help_text="$(gcloud $subcommand --help 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true)"
if [ -z "$help_text" ]; then
  report "could not read \`gcloud $subcommand --help\`; cannot validate Sol's argv"
fi

flag_documented() {
  printf '%s\n' "$help_text" | grep -qE "(^|[^-[:alnum:]])$1([^-[:alnum:]]|\$)"
}

for flag in "${flags[@]}"; do
  if ! flag_documented "$flag"; then
    report "gcloud's \`$subcommand\` does not document $flag, but Sol passes it"
  fi
done

if flag_documented --kubeconfig; then
  report "--kubeconfig now exists on \`$subcommand\`; revisit whether Sol should use it"
fi

if ! grep -q 'gcp_provisioner_kubeconfig' "$source_file"; then
  report "the GCP cluster-access function Sol uses is gone; this check is now vacuous"
fi
gcp_access_fn="$(sed -n '/^let gcp_provisioner_kubeconfig/,/^let gcp_cloud_ready/p' "$source_file")"
if [ -z "$gcp_access_fn" ]; then
  report "could not extract the GCP cluster-access function for inspection"
fi
for flag in --kubeconfig; do
  if printf '%s\n' "$gcp_access_fn" | grep -qF "\"$flag\""; then
    report "Sol passes $flag to \`$subcommand\`, which does not accept it (Attempt 2)"
  fi
done
if ! printf '%s\n' "$gcp_access_fn" | grep -q 'provisioner_kube_env path'; then
  report "the GCP access call no longer exports its own KUBECONFIG"
fi

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
if ! grep -q '"provisioner_impersonator", Gcp' \
  "$root/cli/lib/base/sol_cli_provider.ml"; then
  report "Sol's provider tier does not assign provisioner_impersonator to the gcp block (Sol_cli_provider.owned_legacy_keys)"
fi
if ! grep -q 'provider_field target "provisioner_impersonator"' \
  "$root/cli/lib/cloud/sol_cli_provider_capabilities.ml"; then
  report "the GCP capabilities do not read the target's provisioner_impersonator"
fi

[ "$fail" -eq 0 ] || exit 1
echo "check_gcloud_interface: Sol's GCP cluster-access argv matches the real gcloud interface; the impersonation grant is scoped to the named identity and the declared caller."
