#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(git rev-parse --show-toplevel)}"
cd "$root"

status=0

placeholders='111122223333|123456789012|000000000000'

account_qualifier='([Aa]ccount|(^|[^A-Za-z])[Aa][Ww][Ss]|arn:|(us|eu|ap|sa|ca|me|af|cn|il)(-gov)?-[a-z]+-[0-9])'

found="$(git grep -nI -E "(arn:aws:[a-zA-Z0-9-]*:[a-zA-Z0-9-]*:[0-9]{12}:|[0-9]{12}\\.dkr\\.ecr|[Aa]ccount[^0-9]{0,12}[0-9]{12}|(^|[^0-9/])[0-9]{12}[^0-9]{0,16}${account_qualifier}|${account_qualifier}[^0-9]{0,16}(^|[^0-9/])[0-9]{12})" 2>/dev/null | grep -vE "$placeholders" || true)"

if [ -n "$found" ]; then
  echo "FAIL: real-looking AWS account id in a tracked file:" >&2
  echo "$found" >&2
  echo "      Tracked material must not carry a real account id; use a documented" >&2
  echo "      placeholder or keep qualification artifacts outside the repository." >&2
  status=1
fi

scratch="$(git ls-files | grep -E '(^|/)(sol/(qual[0-9]*)/|sol/environments\.local\.yml$|backend\.tf$)' || true)"
if [ -n "$scratch" ]; then
  echo "FAIL: qualification scratch files are tracked by git:" >&2
  echo "$scratch" >&2
  echo "      Provisioned targets and backend overrides belong outside the repo;" >&2
  echo "      see HARDEN-002 (run 2) on why this is checked mechanically." >&2
  status=1
fi

if [ "$status" = "0" ]; then
  echo "qualification artifacts: no account ids or scratch files in the repository"
fi
exit "$status"
