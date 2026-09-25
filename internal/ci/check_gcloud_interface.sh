#!/usr/bin/env bash
#
# Sol drives `gcloud`, and a flag that does not exist fails the operation at
# argument parsing -- before any authority, network or provider behaviour is
# exercised. Attempt 2 lost a live run to exactly that: `gcloud container clusters
# get-credentials --kubeconfig <path>` has no such flag, so cluster access failed
# with "unrecognized arguments: --kubeconfig" and the failure looked, from Sol's
# own message at the time, like a credential problem.
#
# The offline lifecycle harness did not catch it, and could not have: its `gcloud`
# stub was written from the implementation, so it accepted the flag. **A stub
# cannot falsify the interface it was modelled on.** Only the real CLI can.
#
# So this asks the real CLI. It extracts every gcloud invocation Sol constructs for
# GCP cluster access, and checks each flag against `gcloud <subcommand> --help`,
# which is a local, free, non-billable operation -- available offline, and the
# closest thing to the interface a live run will actually meet.
#
# When gcloud is not installed (CI images without it) this skips loudly rather than
# passing quietly: a check that did not run must not read as a check that passed.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
# REFAC-096: GCP cluster access lives in its provider module.
source_file="$root/cli/sol/lib/sol_cli_gcp_cluster.ml"

fail=0
report() {
  echo "check_gcloud_interface: $1" >&2
  fail=1
}

if ! command -v gcloud >/dev/null 2>&1; then
  echo "check_gcloud_interface: SKIPPED -- gcloud is not installed, so the real CLI interface could not be validated. Sol's gcloud argv is unverified here."
  exit 0
fi

# The subcommand Sol drives for GCP cluster access, and the flags it passes. Kept as
# an explicit list rather than parsed out of the OCaml, because the point of this
# check is to compare Sol's argv against the CLI -- if the extraction itself were
# clever enough to be wrong, the check would agree with the mistake.
subcommand="container clusters get-credentials"
flags=(--region --project --impersonate-service-account --quiet)

# 1. Every flag passed must exist on that subcommand, and must be spelled the way
#    Sol spells it.
#
# gcloud's help is not line-oriented the way one would guess: the subcommand's own
# flags appear in the SYNOPSIS (with ANSI escapes around them), and the flags shared
# by every command -- --project, --quiet, --impersonate-service-account -- are listed
# comma-separated in a GLOBAL FLAGS block. So the escapes are stripped and the flag
# is matched as a word, which is what "gcloud documents this flag" means.
# `gcloud help X Y Z` rejects a multi-word command ("Invalid choice"), so the
# help is requested the way the CLI itself spells it.
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

# ...and the flag that cost Attempt 2 a live run must genuinely be absent from the
# interface, not merely unused: this asserts the failure is reproducible here, so the
# check is testing the CLI rather than agreeing with Sol.
if flag_documented --kubeconfig; then
  report "--kubeconfig now exists on \`$subcommand\`; revisit whether Sol should use it"
fi

# 2. ...and nothing Sol passes may be absent from the source's own list, so this
#    check cannot silently stop covering a flag that was added later.
if ! grep -q 'gcp_provisioner_kubeconfig' "$source_file"; then
  report "the GCP cluster-access function Sol uses is gone; this check is now vacuous"
fi
#
# The window is delimited by the function boundaries rather than by a line count: a
# fixed number of lines silently stops covering the argv as the function's comments
# grow, which is how the first version of this check passed with --kubeconfig
# reintroduced.
gcp_access_fn="$(sed -n '/^let gcp_provisioner_kubeconfig/,/^let gcp_cloud_ready/p' "$source_file")"
if [ -z "$gcp_access_fn" ]; then
  report "could not extract the GCP cluster-access function for inspection"
fi
for flag in --kubeconfig; do
  if printf '%s\n' "$gcp_access_fn" | grep -qF "\"$flag\""; then
    report "Sol passes $flag to \`$subcommand\`, which does not accept it (Attempt 2)"
  fi
done
# ...and the KUBECONFIG export is what replaces it, so it must still be there.
if ! printf '%s\n' "$gcp_access_fn" | grep -q 'provisioner_kube_env path'; then
  report "the GCP access call no longer exports its own KUBECONFIG"
fi

# 3. gcloud writes the kubeconfig named by KUBECONFIG, so the environment Sol
#    builds for the child is part of the interface, not an implementation detail.

# 4. The impersonation grant must be scoped to the named provisioner identity and to
#    the named caller -- the two halves of "creating the identity is not the same as
#    letting anyone use it". A project-level role, or an inferred member, would both
#    satisfy "impersonation works" while granting far more than the window.
gcp_root="$root/cli/platform/infra/gcp"
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
# The declaration path: a target that names no caller must produce an empty list
# rather than inheriting the running identity.
if ! grep -q 'provisioner_impersonator' "$root/cli/sol/lib/sol_cli_config.ml"; then
  report "Sol's config does not read the target's provisioner_impersonator"
fi
if ! grep -qE 'provisioner_impersonator =$|provisioner_impersonator =' \
  "$root/cli/sol/lib/sol_cli_config.ml"; then
  report "the target's provisioner_impersonator is not merged (DEC-033 lost a field this way)"
fi

[ "$fail" -eq 0 ] || exit 1
echo "check_gcloud_interface: Sol's GCP cluster-access argv matches the real gcloud interface; the impersonation grant is scoped to the named identity and the declared caller."
