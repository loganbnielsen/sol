#!/usr/bin/env bash
set -euo pipefail

sol="$(realpath "${1:-}")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
check() {
  local what="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "test_cloud_bootstrap: $what: expected $expected, got $actual" >&2
    fail=1
  fi
}
check_contains() {
  local what="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *)
      echo "test_cloud_bootstrap: $what: expected to find '$needle' in:" >&2
      echo "$haystack" >&2
      fail=1
      ;;
  esac
}
check_absent() {
  local what="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      echo "test_cloud_bootstrap: $what: did not expect '$needle' in:" >&2
      echo "$haystack" >&2
      fail=1
      ;;
  esac
}

mkdir -p "$tmp/work/sol" "$tmp/bin-ok" "$tmp/bin-refusing"
cat >"$tmp/work/sol.yml" <<'EOF'
project: bootstrap-test
EOF
cat >"$tmp/work/sol/environments.yml" <<'EOF'
qual:
  base_domain: qual-aws.example.test
  targets:
    aws/us-east-1:
      cluster_name: sol-qual-row
      state_bucket: sol-qual-tfstate
      aws:
        state_lock_table: sol-qual-tflock
        provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
        cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
        deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
        operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
barest:
  base_domain: barest.example.test
  targets:
    aws/us-east-1:
      cluster_name: sol-barest
EOF
cat >"$tmp/bin-ok/aws" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/aws.log"
case "\$1 \$2" in
  "route53 list-hosted-zones-by-name")
    printf '%s\n' '{"HostedZones":[{"Name":"qual-aws.example.test."}]}'
    ;;
esac
exit 0
EOF
cat >"$tmp/bin-refusing/aws" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "s3api head-bucket" | "dynamodb describe-table")
    exit 254
    ;;
  "iam get-role")
    printf '%s' "An error occurred (NoSuchEntity) when calling the GetRole operation" >&2
    exit 254
    ;;
  "route53 list-hosted-zones-by-name")
    printf '%s\n' '{"HostedZones":[]}'
    ;;
esac
exit 0
EOF
chmod +x "$tmp/bin-ok/aws" "$tmp/bin-refusing/aws"

run() {
  local path="$1" target="$2"
  set +e
  output="$(cd "$tmp/work" && PATH="$path" "$sol" cloud bootstrap "$target" 2>&1)"
  rc=$?
  set -e
}

run "$tmp/bin-ok:/usr/bin:/bin" qual/aws/us-east-1
check "an established installation exits 0" 0 "$rc"
check_contains "the report names the stage" "CloudBootstrap" "$output"
check_contains \
  "the state backend is observed established" \
  "terraform state backend      Established" \
  "$output"
check_contains \
  "the delegated zone is observed established" \
  "delegated DNS zone           Established" \
  "$output"
check_contains "the installation is reported established" "The installation is established" "$output"
check_contains \
  "the probe asks for the role by name, not by ARN" \
  "iam get-role --role-name sol-provisioner" \
  "$(cat "$tmp/aws.log")"
check_absent \
  "no probe passes the declared ARN as a role name" \
  "role-name arn:aws:iam" \
  "$(cat "$tmp/aws.log")"

run "$tmp/bin-refusing:/usr/bin:/bin" qual/aws/us-east-1
check "a refusing provider exits 1" 1 "$rc"
check_contains "the state backend is Unmet" "terraform state backend      Unmet" "$output"
check_contains \
  "the identity carries the provider's own answer" \
  "provisioning identity        Unmet: An error occurred (NoSuchEntity)" \
  "$output"
check_contains \
  "an empty hosted-zone answer is Unmet, not Established" \
  "delegated DNS zone           Unmet: no Route53 hosted zone named qual-aws.example.test" \
  "$output"

run "/usr/bin:/bin" qual/aws/us-east-1
check "a provider CLI that cannot run exits 1" 1 "$rc"
check_contains "an unobservable probe is UNKNOWN" "UNKNOWN: spawn failed" "$output"

run "$tmp/bin-ok:/usr/bin:/bin" barest/aws/us-east-1
check "a target with no state backend exits 1" 1 "$rc"
check_contains "the refusal names state_bucket" "requires the target's state_bucket" "$output"

run "$tmp/bin-ok:/usr/bin:/bin" nope/aws/us-east-1
check "an undeclared target exits 1" 1 "$rc"
check_contains "the refusal names the target" "nope/aws/us-east-1 is not declared" "$output"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "test_cloud_bootstrap: the installation surface observes, and fails closed."
