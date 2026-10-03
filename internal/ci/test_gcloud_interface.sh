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
for tool in bash cat git grep sed tr; do
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

write_access_fn
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "DEBUG root Failed to check metadata server: %%s\\n" "Name or service not known" >&2\n'
  printf 'exit 0\n'
} >"$tools/gcloud"
chmod +x "$tools/gcloud"
run_fixture && fail "a gcloud that printed non-help text was accepted as validated"
out="$(cat "$fixture/out")"
case "$out" in
  *"produced no usable help (exit 0)"*) ;;
  *) fail "non-help output was not reported as unusable help with its exit status: $(show_fixture_out)" ;;
esac
case "$out" in
  *"metadata server"*) ;;
  *) fail "the unusable-help report omitted what gcloud did print: $(show_fixture_out)" ;;
esac
case "$out" in
  *"does not document"*) fail "non-help output was reported as a missing flag" ;;
  *) echo "  [OK]   non-help output is unusable help — exit status and output named, never a missing flag" ;;
esac

{
  printf '#!/usr/bin/env bash\n'
  printf 'cat "%s"\n' "$help"
  printf 'exit 1\n'
} >"$tools/gcloud"
chmod +x "$tools/gcloud"
run_fixture && fail "a gcloud whose --help exited non-zero was accepted"
out="$(cat "$fixture/out")"
case "$out" in
  *"produced no usable help (exit 1)"*) ;;
  *) fail "a non-zero help exit was not reported with its exit status: $(show_fixture_out)" ;;
esac
case "$out" in
  *"does not document"*) fail "a non-zero help exit was reported as a missing flag" ;;
  *) echo "  [OK]   a non-zero help exit is reported as unusable help, never as a missing flag" ;;
esac

{
  printf 'SYNOPSIS\n'
  printf '    gcloud container clusters get-credentials [NAME]\n'
  printf '      --project --impersonate-service-account --quiet\n'
} >"$help"
{
  printf '#!/usr/bin/env bash\n'
  printf 'cat "%s"\n' "$help"
} >"$tools/gcloud"
chmod +x "$tools/gcloud"
run_fixture && fail "usable help that lacks a required flag was accepted"
out="$(cat "$fixture/out")"
case "$out" in
  *"does not document --region"*) ;;
  *) fail "real help lacking --region did not produce the flag-absent report: $(show_fixture_out)" ;;
esac
case "$out" in
  *"produced no usable help"*) fail "usable help was misreported as unreadable" ;;
  *) echo "  [OK]   usable help that lacks a flag still fails with the flag-absent message" ;;
esac

echo "gcloud interface guard: all expectations hold."
