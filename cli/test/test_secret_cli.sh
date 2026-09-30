#!/bin/sh
set -eu
sol=$1
for action in set list delete; do
  remote=$("$sol" secret "$action" --help=plain)
  local_help=$("$sol" local secret "$action" --help=plain)
  printf '%s\n' "$remote" | grep -F -- '--target=ENV/PROVIDER/REGION' >/dev/null
  printf '%s\n' "$local_help" | grep -F "sol local secret $action" >/dev/null
  if printf '%s\n' "$remote" "$local_help" | grep -F -- '--env=' >/dev/null; then exit 1; fi
  if printf '%s\n' "$local_help" | grep -F -- '--target=' >/dev/null; then exit 1; fi
done
if "$sol" secret set DATABASE_URL --env prod --target prod/aws/us-east-1 --value x >/dev/null 2>&1; then exit 1; else test "$?" -eq 124; fi
if "$sol" local secret set DATABASE_URL --target prod/aws/us-east-1 --value x >/dev/null 2>&1; then exit 1; else test "$?" -eq 124; fi
