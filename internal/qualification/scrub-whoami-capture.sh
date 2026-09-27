#!/usr/bin/env bash
set -euo pipefail

in="${1:?usage: scrub-whoami-capture.sh <capture.json> [out.json]}"
out="${2:-${in%.json}.scrubbed.json}"

[ -f "$in" ] || {
  echo "scrub-whoami-capture: no such capture: $in" >&2
  exit 1
}

jq 'walk(if type == "string"
          then gsub("(?<pre>arn:[^:]*:[^:]*:[^:]*:)[0-9]{12}(?<post>:)";
                    "\(.pre)111122223333\(.post)")
          else . end)
    | walk(if type == "object"
           then with_entries(
                  if (.key | test("^(uid|principalId|accessKeyId|sessionName)$"))
                  then .value = "scrubbed"
                  else . end)
           else . end)' "$in" >"$out"

if grep -Eo '[0-9]{12}' "$out" | grep -qv '^111122223333$'; then
  echo "scrub-whoami-capture: a 12-digit account id survived the scrub -- do not commit this" >&2
  exit 1
fi

echo "scrubbed: $out"
