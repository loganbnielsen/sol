#!/usr/bin/env bash

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
helpers="$root/internal/ci/lib/stray_terraform_state.sh"

# shellcheck source=lib/stray_terraform_state.sh
. "$helpers"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

tree="$tmp/assets"
mkdir -p "$tree/cloud/aws/cluster" "$tree/cloud/gcp/cluster"
printf '# fixture\n' >"$tree/cloud/aws/cluster/main.tf"
printf '# stale\n' >"$tree/cloud/aws/cluster/stale.tfstate"

marker="$tmp/marker"
printf 'marker\n' >"$marker"

fail=0

run() {
  out="$(stray_terraform_state "$tree" "$marker" 2>&1)"
  status=$?
}

expect_clean() {
  run
  if [ "$status" -ne 0 ] || [ -n "$out" ]; then
    echo "test_stray_terraform_state: $1: expected a clean scan, got status=$status out='$out'." >&2
    fail=1
  fi
}

expect_report() {
  run
  if [ "$status" -ne 0 ]; then
    echo "test_stray_terraform_state: $1: expected a report, got status=$status out='$out'." >&2
    fail=1
    return
  fi
  case "$out" in
    *"$2"*) ;;
    *)
      echo "test_stray_terraform_state: $1: the report does not name $2: '$out'." >&2
      fail=1
      ;;
  esac
}

expect_clean "a tree whose only state file predates the marker"

mkdir -p "$tree/cloud/aws/cluster/.terraform"
printf 'plugin\n' >"$tree/cloud/aws/cluster/.terraform/plugin"
expect_report "a .terraform directory newer than the marker" ".terraform"

rm -rf "$tree/cloud/aws/cluster/.terraform"
printf 'state\n' >"$tree/cloud/gcp/cluster/terraform.tfstate"
expect_report "a .tfstate newer than the marker" "gcp/cluster/terraform.tfstate"

rm -f "$tree/cloud/gcp/cluster/terraform.tfstate"
printf 'errored\n' >"$tree/cloud/aws/cluster/errored.tfstate"
expect_report "an errored.tfstate newer than the marker" "errored.tfstate"

rm -f "$tree/cloud/aws/cluster/errored.tfstate"
bin="$tmp/bin"
mkdir -p "$bin"
ln -s "$(command -v bash)" "$bin/bash"
printf '#!/usr/bin/env bash\nexit 1\n' >"$bin/find"
chmod +x "$bin/find"
out="$(env PATH="$bin" bash -c '. "$1"; stray_terraform_state "$2" "$3"' _ "$helpers" "$tree" "$marker" 2>&1)"
status=$?
if [ "$status" -ne 1 ]; then
  echo "test_stray_terraform_state: a find that cannot run: expected a refusal, got status=$status out='$out'." >&2
  fail=1
fi
case "$out" in
  *"could not scan"*) ;;
  *)
    echo "test_stray_terraform_state: a find that cannot run is not reported as unscannable: '$out'." >&2
    fail=1
    ;;
esac

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "test_stray_terraform_state: the scan reports new Terraform state of every kind, ignores state that predates the marker, and refuses rather than passing when it cannot scan."
