#!/usr/bin/env bash
set -euo pipefail

# DEC-040: turn a captured `kubectl auth whoami -o json` response into something that can
# live in the repository as a fixture.
#
# A real response carries a 12-digit AWS account id, which the account-artifact guard
# rejects -- correctly. Scrub it, keep the original outside the repository, and preserve the
# *structure*: array wrapping, key names and ARN shape are exactly the detail the parser
# depends on, and a scrubber that flattens them would destroy the thing it exists to
# protect.
#
#   ./scrub-whoami-capture.sh <capture.json> [out.json]
#
# The account becomes the repository's documented placeholder, so a fixture written from a
# capture is committable as-is.

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

# Fail loudly rather than emit a fixture that still carries an account id.
# The documented placeholder is itself 12 digits, so the criterion is "no account id other
# than the placeholder" -- the same rule the account-artifact guard applies.
if grep -Eo '[0-9]{12}' "$out" | grep -qv '^111122223333$'; then
  echo "scrub-whoami-capture: a 12-digit account id survived the scrub -- do not commit this" >&2
  exit 1
fi

echo "scrubbed: $out"
