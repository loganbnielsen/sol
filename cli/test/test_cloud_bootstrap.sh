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

mkdir -p "$tmp/work/sol" "$tmp/bin-ok" "$tmp/bin-refusing" "$tmp/bin-denied" "$tmp/bin-tf" "$tmp/data"
cat >"$tmp/bin-tf/terraform" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/terraform.log"
case " \$* " in
  *" state list "*) cat "$tmp/state-list" 2>/dev/null || printf 'aws_s3_bucket.state\n'; exit 0 ;;
  *" init "*) exit 0 ;;
  *" plan "*)
    for argument in "\$@"; do
      case "\$argument" in
        -out=*) : >"\${argument#-out=}" ;;
      esac
    done
    exit 0
    ;;
  *" show "*) cat "$tmp/plan.json"; exit 0 ;;
  *" output -json "*) cat "$tmp/outputs.json"; exit 0 ;;
  *" apply "*) exit 0 ;;
esac
exit 0
EOF
chmod +x "$tmp/bin-tf/terraform"
printf '%s\n' \
  '{"dns_zone_nameservers":{"sensitive":false,"value":["ns-1.awsdns.test","ns-2.awsdns.test"]}}' \
  >"$tmp/outputs.json"
cat >"$tmp/work/sol.yml" <<'EOF'
project: bootstrap-test
EOF
cat >"$tmp/work/sol/environments.yml" <<'EOF'
qual:
  base_domain: qual-aws.example.test
  dns_zone_ownership: sol
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
  dns_zone_ownership: user
  targets:
    aws/us-east-1:
      cluster_name: sol-barest

undeclared:
  base_domain: undeclared.example.test
  targets:
    aws/us-east-1:
      cluster_name: sol-undeclared
      state_bucket: sol-undeclared-tfstate
      aws:
        state_lock_table: sol-undeclared-tflock
        provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
        cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
        deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
        operator_role_arn: arn:aws:iam::111122223333:role/sol-operator

byo:
  base_domain: byo.example.test
  dns_zone_ownership: external
  targets:
    aws/us-east-1:
      cluster_name: sol-byo
      state_bucket: sol-byo-tfstate
      aws:
        state_lock_table: sol-byo-tflock
        provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
        cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
        deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
        operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
EOF
cat >"$tmp/bin-ok/dig" <<'EOF'
#!/bin/sh
printf '%s\n' 'ns-1.awsdns.test.'
printf '%s\n' 'ns-2.awsdns.test.'
exit 0
EOF
chmod +x "$tmp/bin-ok/dig"
cat >"$tmp/bin-ok/aws" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/aws.log"
case "\$1 \$2" in
  "configure export-credentials")
    printf 'export AWS_ACCESS_KEY_ID=AKIAEXAMPLE\n'
    printf 'export AWS_SECRET_ACCESS_KEY=example-secret\n'
    ;;
  "route53 list-hosted-zones-by-name")
    case " \$* " in
      *" --query "*)
        case " \$* " in
          *"--dns-name example.test "*) cat "$tmp/parent-zone-id" 2>/dev/null ;;
          *) cat "$tmp/existing-zone-id" 2>/dev/null ;;
        esac
        ;;
      *) printf '%s\n' '{"HostedZones":[{"Name":"qual-aws.example.test."}]}' ;;
    esac
    ;;
esac
exit 0
EOF
cat >"$tmp/bin-refusing/aws" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "configure export-credentials")
    printf 'export AWS_ACCESS_KEY_ID=AKIAEXAMPLE\n'
    printf 'export AWS_SECRET_ACCESS_KEY=example-secret\n'
    ;;
  "s3api head-bucket")
    printf '%s\n' 'An error occurred (404) when calling the HeadBucket operation: Not Found' >&2
    exit 254
    ;;
  "dynamodb describe-table")
    printf '%s\n' 'An error occurred (ResourceNotFoundException) when calling the DescribeTable operation: Requested resource not found' >&2
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
cat >"$tmp/bin-denied/aws" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "configure export-credentials")
    printf 'export AWS_ACCESS_KEY_ID=AKIAEXAMPLE\n'
    printf 'export AWS_SECRET_ACCESS_KEY=example-secret\n'
    ;;
esac
printf '%s\n' 'An error occurred (AccessDenied) when calling the operation: not authorized to perform this action' >&2
exit 255
EOF
chmod +x "$tmp/bin-ok/aws" "$tmp/bin-refusing/aws" "$tmp/bin-denied/aws"

run() {
  local path="$1" target="$2"
  shift 2
  set +e
  output="$(
    cd "$tmp/work" && XDG_DATA_HOME="$tmp/data" PATH="$path" "$sol" cloud bootstrap "$target" "$@" 2>&1
  )"
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
  "the delegation is observed through a public resolver" \
  "public delegation            Established" \
  "$output"

run "$tmp/bin-ok:/usr/bin:/bin" qual/aws/us-east-1 --await-delegation=5
check "waiting for a delegation that is already public exits 0" 0 "$rc"
check_contains \
  "the waited verdict is printed" \
  "public delegation           Established" \
  "$output"
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
  "delegated DNS zone           Unmet: no Route53 hosted zone named qual-aws.example.test, although the target declares it sol-created" \
  "$output"

run "$tmp/bin-denied:/usr/bin:/bin" qual/aws/us-east-1
check "a provider that refuses to answer exits 1" 1 "$rc"
check_contains \
  "a denied answer is UNKNOWN, not an absent prerequisite" \
  "terraform state backend      UNKNOWN: An error occurred (AccessDenied)" \
  "$output"
check_contains \
  "a denied identity read is UNKNOWN too" \
  "provisioning identity        UNKNOWN: An error occurred (AccessDenied)" \
  "$output"
check_absent \
  "a denied answer is never reported as Unmet" \
  "terraform state backend      Unmet" \
  "$output"

run "/usr/bin:/bin" qual/aws/us-east-1
check "a provider CLI that cannot run exits 1" 1 "$rc"
check_contains "an unobservable probe is UNKNOWN" "UNKNOWN: spawn failed" "$output"

run "$tmp/bin-ok:/usr/bin:/bin" barest/aws/us-east-1
check "a target with no state backend exits 1" 1 "$rc"
check_contains "the refusal names state_bucket" "requires the target's state_bucket" "$output"

run "$tmp/bin-ok:/usr/bin:/bin" undeclared/aws/us-east-1
check "a declared domain with no ownership declaration exits 1" 1 "$rc"
check_contains "the refusal names dns_zone_ownership" "declares no dns_zone_ownership" "$output"

run "$tmp/bin-ok:/usr/bin:/bin" byo/aws/us-east-1
check "an externally delegated zone is not reported established" 1 "$rc"
check_contains \
  "an externally delegated zone is UNKNOWN, not Unmet" \
  "delegated DNS zone           UNKNOWN: byo.example.test is externally delegated" \
  "$output"

run "$tmp/bin-ok:/usr/bin:/bin" nope/aws/us-east-1
check "an undeclared target exits 1" 1 "$rc"
check_contains "the refusal names the target" "nope/aws/us-east-1 is not declared" "$output"

printf '%s\n' \
  '{"resource_changes":[{"address":"aws_s3_bucket.state","type":"aws_s3_bucket","mode":"managed","change":{"actions":["update"]}}]}' \
  >"$tmp/plan.json"
rm -f "$tmp/terraform.log"
run "$tmp/bin-ok:$tmp/bin-tf:/usr/bin:/bin" qual/aws/us-east-1 --apply
check "a reconciled durable root exits 0" 0 "$rc"
check_contains "the reconcile applied the plan" " apply " "$(cat "$tmp/terraform.log")"
check_contains "the reconcile planned before applying" " plan " "$(cat "$tmp/terraform.log")"
check_contains \
  "the durable root gets a state of its own" \
  "aws-bootstrap" \
  "$(cat "$tmp/terraform.log")"
check_contains "the installation is established after the reconcile" "The installation is established" "$output"
check_contains \
  "the delegation instruction names the zone's domain and parent" \
  "add these NS records for qual-aws.example.test at the zone that publishes it (example.test)" \
  "$output"
check_contains "the instruction lists the zone's nameservers" "NS  ns-1.awsdns.test" "$output"
check_contains "and the second nameserver" "NS  ns-2.awsdns.test" "$output"
mv "$tmp/outputs.json" "$tmp/outputs.hidden"
run "$tmp/bin-ok:$tmp/bin-tf:/usr/bin:/bin" qual/aws/us-east-1 --apply
check_contains \
  "a root with no zone yet says so instead of printing an empty list" \
  "is not observable yet" \
  "$output"
mv "$tmp/outputs.hidden" "$tmp/outputs.json"

printf '%s\n' '/hostedzone/ZADOPTED' >"$tmp/existing-zone-id"
rm -f "$tmp/state-list" "$tmp/terraform.log"
run "$tmp/bin-ok:$tmp/bin-tf:/usr/bin:/bin" qual/aws/us-east-1 --apply
check "adopting an existing zone exits 0" 0 "$rc"
check_contains "the run says it is adopting, not creating" "adopting it" "$output"
check_contains \
  "the counted zone is imported, not created" \
  "aws_route53_zone.qualification[0]" \
  "$(cat "$tmp/terraform.log")"
check_contains \
  "the import identity is the zone that already exists" \
  "/hostedzone/ZADOPTED" \
  "$(cat "$tmp/terraform.log")"

rm -f "$tmp/existing-zone-id" "$tmp/terraform.log"
run "$tmp/bin-ok:$tmp/bin-tf:/usr/bin:/bin" qual/aws/us-east-1 --apply
check "creating a zone that does not exist exits 0" 0 "$rc"
check_contains "the run says the root creates it" "creates it" "$output"
check_absent "nothing is imported when there is nothing to adopt" " import " "$(cat "$tmp/terraform.log")"

printf '%s\n' '/hostedzone/ZPARENT' >"$tmp/parent-zone-id"
rm -f "$tmp/terraform.log"
run "$tmp/bin-ok:$tmp/bin-tf:/usr/bin:/bin" qual/aws/us-east-1 --apply
check "a parent zone in the account exits 0" 0 "$rc"
check_contains \
  "the durable root writes the delegation when the parent is in the account" \
  "the durable root writes the NS delegation itself" \
  "$output"
check_contains \
  "and the parent's identity is passed to the root" \
  "parent_zone_id=/hostedzone/ZPARENT" \
  "$(cat "$tmp/terraform.log")"
check_absent \
  "nothing is asked of the operator when Sol can write the delegation" \
  "add these NS records" \
  "$output"
rm -f "$tmp/parent-zone-id"

printf '%s\n' 'aws_s3_bucket.state' 'aws_route53_zone.qualification[0]' >"$tmp/state-list"
rm -f "$tmp/terraform.log"
run "$tmp/bin-ok:$tmp/bin-tf:/usr/bin:/bin" qual/aws/us-east-1 --apply
check "a zone the root already owns exits 0" 0 "$rc"
check_contains \
  "the counted instance counts as owned" \
  "already owns the zone for qual-aws.example.test" \
  "$output"
check_absent "an owned zone is not imported again" " import " "$(cat "$tmp/terraform.log")"
rm -f "$tmp/state-list"

run "$tmp/bin-ok:$tmp/bin-tf:/usr/bin:/bin" byo/aws/us-east-1 --apply
check_absent \
  "a zone Sol does not own gets no delegation instruction" \
  "add these NS records" \
  "$output"

printf '%s\n' '{"resource_changes":[]}' >"$tmp/plan.json"
rm -f "$tmp/terraform.log"
run "$tmp/bin-ok:$tmp/bin-tf:/usr/bin:/bin" qual/aws/us-east-1 --apply
check "a root already at its declared state exits 0" 0 "$rc"
check_contains "a second run still plans" " plan " "$(cat "$tmp/terraform.log")"

printf '%s\n' \
  '{"resource_changes":[{"address":"aws_s3_bucket.state","type":"aws_s3_bucket","mode":"managed","change":{"actions":["delete","create"]}}]}' \
  >"$tmp/plan.json"
rm -f "$tmp/terraform.log"
run "$tmp/bin-ok:$tmp/bin-tf:/usr/bin:/bin" qual/aws/us-east-1 --apply
check "a plan that would replace a durable resource exits 1" 1 "$rc"
check_contains "the refusal names the resource" "aws_s3_bucket.state" "$output"
check_contains "the refusal is a refusal" "refused" "$output"
check_absent "a refused plan is never applied" "apply" "$(cat "$tmp/terraform.log")"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "test_cloud_bootstrap: the installation surface observes, and fails closed."
