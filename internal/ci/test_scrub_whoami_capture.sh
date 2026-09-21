#!/usr/bin/env bash
set -euo pipefail

# DEC-040: proves the capture scrubber preserves structure while removing account ids.
#
# The sample is *generated*, not written as a literal: a tracked file carrying a 12-digit
# account id is exactly what the account-artifact guard exists to reject, and a test that
# tripped it would be the wrong kind of irony.

repo="${1:-$(git rev-parse --show-toplevel)}"
scrub="$repo/internal/pipeline/qualification/scrub-whoami-capture.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A 12-digit account that is not the documented placeholder, built at runtime.
other_account="$(printf '9%.0s' $(seq 1 12))"

cat >"$work/capture.json" <<JSON
{
  "apiVersion": "authentication.k8s.io/v1",
  "kind": "SelfSubjectReview",
  "status": {
    "userInfo": {
      "username": "arn:aws:sts::${other_account}:assumed-role/sol-provisioner/EKSGetTokenAuth",
      "uid": "aws-iam-authenticator:${other_account}:AROAEXAMPLE",
      "groups": ["system:authenticated", "sol:platform-provisioners"],
      "extra": {
        "arn": ["arn:aws:sts::${other_account}:assumed-role/sol-provisioner/EKSGetTokenAuth"],
        "canonicalArn": ["arn:aws:iam::${other_account}:role/sol-provisioner"],
        "sessionName": ["EKSGetTokenAuth"],
        "principalId": ["AROAEXAMPLE:logan"]
      }
    }
  }
}
JSON

bash "$scrub" "$work/capture.json" "$work/scrubbed.json" >/dev/null

fail() {
  echo "test_scrub_whoami_capture: $1" >&2
  exit 1
}

# 1. No account id survives -- the guard's own criterion.
if grep -Eo '[0-9]{12}' "$work/scrubbed.json" | grep -qv '^111122223333$'; then
  fail "an account id other than the placeholder survived the scrub"
fi

# 2. The placeholder is present.
grep -q '111122223333' "$work/scrubbed.json" ||
  fail "the documented placeholder is missing from the scrubbed capture"

# 3. Structure is preserved: the array wrapping and key names are the detail the parser
#    depends on, so a scrubber that flattened them would destroy the point.
jq -e '.status.userInfo.extra.canonicalArn | type == "array"' "$work/scrubbed.json" >/dev/null ||
  fail "canonicalArn is no longer an array"
jq -e '.status.userInfo.extra.canonicalArn | length == 1' "$work/scrubbed.json" >/dev/null ||
  fail "the array length changed"
jq -e '.apiVersion == "authentication.k8s.io/v1" and .kind == "SelfSubjectReview"' \
  "$work/scrubbed.json" >/dev/null || fail "the envelope was not preserved"
jq -e '.status.userInfo.extra.arn[0] | test("^arn:aws:sts::111122223333:assumed-role/sol-provisioner/")' \
  "$work/scrubbed.json" >/dev/null || fail "the ARN shape was not preserved"

# 4. Identifying fields are scrubbed.
for f in uid sessionName principalId; do
  v="$(jq -r --arg f "$f" '.status.userInfo.extra[$f] // .status.userInfo[$f]' "$work/scrubbed.json")"
  case "$v" in
    *scrubbed*) : ;;
    *) fail "$f was not scrubbed (got: $v)" ;;
  esac
done

echo "scrub-whoami-capture: structure preserved, account ids removed"
