#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_provider_roots.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkrepo() {
  rm -rf "$tmp/repo"
  for p in aws gcp; do
    for role in bootstrap cluster platform authorization; do
      mkdir -p "$tmp/repo/platform/cloud/$p/$role"
      echo '# fixture' >"$tmp/repo/platform/cloud/$p/$role/main.tf"
    done
  done
  mkdir -p "$tmp/repo/platform/cloud/modules/platform" "$tmp/repo/platform/cloud/delivery/ci"
}

expect() {
  local want="$1" name="$2" providers="$3"
  if SOL_PROVIDERS="$providers" "$CHECK" "$tmp/repo" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" != "$want" ]; then
    echo "  [FAIL] $name (expected $want, got $got)"
    exit 1
  fi
  echo "  [OK]   $name"
}

present=$'aws\tpresent\ngcp\tpresent'

mkrepo
expect pass "two providers with every role" "$present"

mkrepo
expect pass "a registered provider with no directory is on paper (S11)" "$present"$'\nazure\tnot_implemented'

mkrepo
expect pass "a rootless-by-definition driver with no directory" "$present"$'\nbyo\tnot_applicable'

mkrepo
mkdir -p "$tmp/repo/platform/cloud/byo/cluster"
echo '# fixture' >"$tmp/repo/platform/cloud/byo/cluster/main.tf"
expect fail "a rootless-by-definition driver that has a directory" "$present"$'\nbyo\tnot_applicable'

mkrepo
rm -rf "$tmp/repo/platform/cloud/aws"
expect fail "a driver that declares a root but has none" "$present"

mkrepo
rm -rf "$tmp/repo/platform/cloud/gcp/bootstrap"
expect fail "a provider with a directory but a missing role" "$present"

mkrepo
rm -f "$tmp/repo/platform/cloud/gcp/cluster/main.tf"
expect fail "a role directory with no Terraform in it" "$present"

mkrepo
mkdir -p "$tmp/repo/platform/cloud/azure/cluster"
echo '# fixture' >"$tmp/repo/platform/cloud/azure/cluster/main.tf"
expect fail "an unregistered directory under platform/cloud/" "$present"

mkrepo
mkdir -p "$tmp/repo/platform/cloud/azure/cluster"
echo '# fixture' >"$tmp/repo/platform/cloud/azure/cluster/main.tf"
expect fail "a registered provider that is half built" "$present"$'\nazure\tnot_implemented'

mkrepo
rm -rf "$tmp/repo/platform/cloud/aws" "$tmp/repo/platform/cloud/gcp"
expect fail "no provider has roots at all" "$present"

mkrepo
if env -u SOL_PROVIDERS "$CHECK" "$tmp/repo" >/dev/null 2>&1; then
  echo "  [FAIL] an unreadable provider list fails closed"
  exit 1
fi
echo "  [OK]   an unreadable provider list fails closed"

"$CHECK" "$ROOT" >/dev/null
echo "  [OK]   the repository's own providers"
