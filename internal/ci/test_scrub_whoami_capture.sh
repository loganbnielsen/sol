#!/usr/bin/env bash
set -euo pipefail

repo="${1:-$(git rev-parse --show-toplevel)}"
scrub="$repo/internal/qualification/scrub-whoami-capture.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

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

if grep -Eo '[0-9]{12}' "$work/scrubbed.json" | grep -qv '^111122223333$'; then
  fail "an account id other than the placeholder survived the scrub"
fi

grep -q '111122223333' "$work/scrubbed.json" ||
  fail "the documented placeholder is missing from the scrubbed capture"

jq -e '.status.userInfo.extra.canonicalArn | type == "array"' "$work/scrubbed.json" >/dev/null ||
  fail "canonicalArn is no longer an array"
jq -e '.status.userInfo.extra.canonicalArn | length == 1' "$work/scrubbed.json" >/dev/null ||
  fail "the array length changed"
jq -e '.apiVersion == "authentication.k8s.io/v1" and .kind == "SelfSubjectReview"' \
  "$work/scrubbed.json" >/dev/null || fail "the envelope was not preserved"
jq -e '.status.userInfo.extra.arn[0] | test("^arn:aws:sts::111122223333:assumed-role/sol-provisioner/")' \
  "$work/scrubbed.json" >/dev/null || fail "the ARN shape was not preserved"

for f in uid sessionName principalId; do
  v="$(jq -r --arg f "$f" '.status.userInfo.extra[$f] // .status.userInfo[$f]' "$work/scrubbed.json")"
  case "$v" in
    *scrubbed*) : ;;
    *) fail "$f was not scrubbed (got: $v)" ;;
  esac
done

echo "scrub-whoami-capture: structure preserved, account ids removed"
