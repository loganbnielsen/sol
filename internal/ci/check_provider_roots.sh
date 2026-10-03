#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
cloud="$root/platform/cloud"

roles="bootstrap cluster platform authorization"
shared="modules delivery"

# shellcheck source=providers.sh
. "$(dirname "$0")/providers.sh"

if ! rows="$(sol_provider_rows "$root")"; then
  echo "check_provider_roots: could not read the provider list" >&2
  exit 1
fi

if ! provider_rows_parse "$rows"; then
  echo "check_provider_roots: the provider list is not a well-formed set of <name><TAB><root_status> rows; refusing to judge the root contract from it:" >&2
  printf '%s\n' "$rows" >&2
  exit 1
fi

if [ ! -d "$cloud" ]; then
  echo "check_provider_roots: $cloud does not exist" >&2
  exit 1
fi

fail=0
real=0
paper=""
for provider in "${PROVIDER_NAMES[@]}"; do
  if ! provider_root_status "$provider"; then
    echo "check_provider_roots: no root_status was read for $provider" >&2
    exit 1
  fi
  status="$PROVIDER_ROOT_STATUS"
  if [ "$status" = "not_applicable" ]; then
    if [ -d "$cloud/$provider" ]; then
      echo "check_provider_roots: $provider owns no root by definition (root_status not_applicable), but platform/cloud/$provider/ exists" >&2
      fail=1
    fi
    continue
  fi
  if [ ! -d "$cloud/$provider" ]; then
    if [ "$status" = "present" ]; then
      echo "check_provider_roots: $provider declares a root (root_status present) but has no platform/cloud/$provider/ directory" >&2
      fail=1
    else
      paper="$paper $provider"
    fi
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
  name="${dir%/}"
  name="${name##*/}"
  case " $shared " in *" $name "*) continue ;; esac
  if ! provider_registered "$name"; then
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
