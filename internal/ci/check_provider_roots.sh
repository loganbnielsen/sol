#!/usr/bin/env bash
# DEC-046 rule 4 (REFAC-100): cloud providers mirror each other by role, and the
# directory is the marker.
#
#   - A registered provider with no platform/cloud/<provider>/ directory is on
#     paper. That is allowed: registering a provider to measure its change surface
#     (the S11 Azure-on-paper test) must stay legal.
#   - A registered provider that has the directory has every role.
#   - Every directory under platform/cloud/ other than modules/ and delivery/ is a
#     registered provider.
#
# Whether a provider is *usable* is the capability layer's question, not this one.
#
# Usage: check_provider_roots.sh [repo-root]
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
cloud="$root/platform/cloud"

# The roles every provider with a directory must have, in one place.
roles="bootstrap cluster platform"
# Directories under platform/cloud/ that are not providers.
shared="modules delivery"

# shellcheck source=providers.sh
. "$(dirname "$0")/providers.sh"
providers="$(sol_providers "$root")" || {
  echo "check_provider_roots: could not read the provider list" >&2
  exit 1
}

if [ ! -d "$cloud" ]; then
  echo "check_provider_roots: $cloud does not exist" >&2
  exit 1
fi

fail=0
real=0
paper=""
for provider in $providers; do
  if [ ! -d "$cloud/$provider" ]; then
    paper="$paper $provider"
    continue
  fi
  real=$((real + 1))
  for role in $roles; do
    if ! compgen -G "$cloud/$provider/$role/*.tf" >/dev/null; then
      echo "check_provider_roots: $provider has platform/cloud/$provider/ but no $role root (no .tf files in platform/cloud/$provider/$role/)" >&2
      fail=1
    fi
  done
done

for dir in "$cloud"/*/; do
  name="$(basename "$dir")"
  case " $shared " in *" $name "*) continue ;; esac
  if ! printf '%s\n' $providers | grep -qx "$name"; then
    echo "check_provider_roots: platform/cloud/$name/ is not a registered provider (Sol_cli_provider.all) and not one of: $shared" >&2
    fail=1
  fi
done

if [ "$real" -eq 0 ]; then
  echo "check_provider_roots: no registered provider has roots under platform/cloud/; a check of nothing is not a pass" >&2
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  echo "check_provider_roots: providers must mirror each other by role (DEC-046 rule 4)" >&2
  exit 1
fi
echo "check_provider_roots: $real provider(s) with every role ($roles)${paper:+; on paper:$paper}"
