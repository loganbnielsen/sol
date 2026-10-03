#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$root/internal/ci/check_gcloud_interface.sh"

fail() {
  echo "  [FAIL] $1" >&2
  exit 1
}

bin="$(mktemp -d)"
trap 'rm -rf "$bin"' EXIT
for tool in bash git grep sed; do
  resolved="$(command -v "$tool" || true)"
  [ -n "$resolved" ] || fail "the fixture needs $tool on PATH"
  ln -s "$resolved" "$bin/$tool"
done

if env PATH="$bin" "$guard" >/dev/null 2>&1; then
  fail "the guard passed without gcloud and without an opt-out"
fi
echo "  [OK]   a missing gcloud fails the guard"

if ! env PATH="$bin" CHECK_GCLOUD_INTERFACE_ALLOW_MISSING_GCLOUD=1 "$guard" >/dev/null 2>&1; then
  fail "the explicit opt-out did not let the guard pass"
fi
echo "  [OK]   the named opt-out runs the static checks and skips only the interface check"

VERIFY_CI_DIR="$root/internal/ci" source "$root/internal/tooling/scripts/verify.sh"
export CHECK_GCLOUD_INTERFACE_ALLOW_MISSING_GCLOUD=1
unset_canonical_inputs
if env PATH="$bin" "$guard" >/dev/null 2>&1; then
  fail "the canonical path let the opt-out reach the guard"
fi
echo "  [OK]   the canonical class runner removes the opt-out before the guard runs"

fixture="$(mktemp -d)"
trap 'rm -rf "$bin" "$fixture"' EXIT
tools="$fixture/tools"
mkdir -p "$tools" "$fixture/cli/lib/cloud" "$fixture/cli/lib/base" "$fixture/platform/cloud/gcp/cluster"
for tool in bash cat git grep sed; do
  ln -s "$(command -v "$tool")" "$tools/$tool"
done
git init -q "$fixture"

filler="wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww"
write_access_fn() {
  {
    printf 'let gcp_provisioner_kubeconfig =\n'
    printf '  provisioner_kube_env path\n'
    [ -z "${1:-}" ] || printf '  %s\n' "$1"
    for i in $(seq 1 3000); do
      printf '  filler %s %s\n' "$i" "$filler"
    done
    printf 'let gcp_cloud_ready =\n'
  } >"$fixture/cli/lib/cloud/sol_cli_gcp_cluster.ml"
}
write_access_fn
{
  printf '  | Gcp ->\n'
  printf '      owned_keys = [ "provisioner_impersonator" ]\n'
  for i in $(seq 1 3000); do
    printf '      filler %s %s\n' "$i" "$filler"
  done
  printf '  | Next ->\n'
} >"$fixture/cli/lib/base/sol_cli_provider.ml"
printf 'let () = provider_field target "provisioner_impersonator"\n' \
  >"$fixture/cli/lib/cloud/sol_cli_provider_capabilities.ml"
{
  printf 'service_account_id = google_service_account.provisioner.name\n'
  printf 'role = "roles/iam.serviceAccountTokenCreator"\n'
  printf 'member = each.value\n'
  printf 'variable "provisioner_impersonators" {}\n'
} >"$fixture/platform/cloud/gcp/cluster/main.tf"
help="$fixture/gcloud-help.txt"
{
  printf 'Usage: gcloud container clusters get-credentials\n'
  printf '  --region  --project  --impersonate-service-account  --quiet\n'
  for i in $(seq 1 3000); do
    printf 'help filler %s %s\n' "$i" "$filler"
  done
} >"$help"
{
  printf '#!/usr/bin/env bash\n'
  printf 'cat "%s"\n' "$help"
} >"$tools/gcloud"
chmod +x "$tools/gcloud"

run_fixture() {
  (cd "$fixture" && env PATH="$tools" "$guard" >"$fixture/out" 2>&1)
}

show_fixture_out() {
  sed -n '1,8p' "$fixture/out"
}

run_fixture || fail "a clean fixture with more than a pipe buffer of provider source was refused: $(show_fixture_out)"
echo "  [OK]   a clean fixture larger than a pipe buffer passes"

write_access_fn '"--kubeconfig"'
run_fixture && fail "a fixture whose access call passes --kubeconfig was accepted"
case "$(cat "$fixture/out")" in
  *"--kubeconfig to \`container clusters get-credentials\`"*) ;;
  *) fail "the refusal does not name --kubeconfig: $(show_fixture_out)" ;;
esac
case "$(cat "$fixture/out")" in
  *"no longer exports its own KUBECONFIG"*) fail "the refusal also reports a missing KUBECONFIG export that this fixture carries" ;;
  *) echo "  [OK]   a passed --kubeconfig is refused, by name, with no invented report" ;;
esac

echo "gcloud interface guard: all expectations hold."
