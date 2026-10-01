#!/usr/bin/env bash
set -euo pipefail

sol="$(realpath "${1:-}")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
check() {
  local what="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "test_uninstall_cli: $what: expected $expected, got $actual" >&2
    fail=1
  fi
}
check_contains() {
  local what="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *)
      echo "test_uninstall_cli: $what: expected to find '$needle' in:" >&2
      echo "$haystack" >&2
      fail=1
      ;;
  esac
}
check_absent() {
  local what="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      echo "test_uninstall_cli: $what: did not expect '$needle' in:" >&2
      echo "$haystack" >&2
      fail=1
      ;;
  esac
}

mkdir -p "$tmp/work/sol" "$tmp/bin" "$tmp/data"
printf '%s\n' 'project: uninstall-test' >"$tmp/work/sol.yml"
cat >"$tmp/work/sol/environments.yml" <<'EOF'
solzone:
  base_domain: sol.example.test
  dns_zone_ownership: sol
  targets:
    aws/us-east-1:
      cluster_name: sol-uninstall-test
      state_bucket: sol-uninstall-tfstate
      aws:
        state_lock_table: sol-uninstall-tflock
        provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
        cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
        deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
        operator_role_arn: arn:aws:iam::111122223333:role/sol-operator

userzone:
  base_domain: user.example.test
  dns_zone_ownership: user
  targets:
    aws/us-east-1:
      cluster_name: sol-uninstall-user
      state_bucket: sol-uninstall-tfstate
      aws:
        state_lock_table: sol-uninstall-tflock
        provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
        cluster_access_role_arn: arn:aws:iam::111122223333:role/sol-cluster-access
        deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
        operator_role_arn: arn:aws:iam::111122223333:role/sol-operator
EOF

cat >"$tmp/bin/terraform" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/terraform.log"
case " \$* " in
  *" state list "*)
    printf '%s\n' \
      'aws_s3_bucket.state' \
      'aws_s3_bucket_versioning.state' \
      'aws_dynamodb_table.lock' \
      'aws_route53_zone.qualification[0]'
    ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/terraform"

cat >"$tmp/bin/aws" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/aws.log"
case "\$1 \$2" in
  "configure export-credentials")
    printf 'export AWS_ACCESS_KEY_ID=AKIAEXAMPLE\n'
    printf 'export AWS_SECRET_ACCESS_KEY=example-secret\n'
    ;;
  "s3api head-bucket" | "dynamodb describe-table" | "iam get-role")
    exit 254
    ;;
  "route53 list-hosted-zones-by-name")
    printf '%s\n' '{"HostedZones":[]}'
    ;;
  "s3api list-object-versions")
    printf '%s\n' '{"Versions":[{"Key":"bootstrap/aws/default.tfstate","VersionId":"v1"}]}'
    ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/aws"

cat >"$tmp/bin/dig" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/dig"

run() {
  local target="$1"
  shift
  : >"$tmp/terraform.log"
  : >"$tmp/aws.log"
  set +e
  output="$(
    cd "$tmp/work" && XDG_DATA_HOME="$tmp/data" PATH="$tmp/bin:/usr/bin:/bin" \
      "$sol" uninstall "$target" "$@" 2>&1
  )"
  rc=$?
  set -e
  commands="$(cat "$tmp/terraform.log")"
}

run solzone/aws/us-east-1
check "an unconfirmed uninstall exits 1" 1 "$rc"
check_contains "the plan names the state backend" "remove  terraform state backend" "$output"
check_contains "the plan names the state lock" "remove  terraform state lock" "$output"
check_contains "the plan names the delegated zone" "remove  delegated DNS zone" "$output"
check_contains \
  "the plan names the DNS confirmation it needs" \
  "--confirm-dns-zone sol.example.test" \
  "$output"
check_contains "the refusal asks for --confirm" "re-run with --confirm" "$output"
check_absent "nothing was destroyed" "destroy" "$commands"
check_absent "nothing was taken out of state" "state rm" "$commands"

run solzone/aws/us-east-1 --confirm
check "a confirmed uninstall without the DNS confirmation exits 1" 1 "$rc"
check_contains "the refusal names the exact zone" "--confirm-dns-zone sol.example.test" "$output"
check_absent "nothing was destroyed" "destroy" "$commands"

run solzone/aws/us-east-1 --confirm --confirm-dns-zone other.example.test
check "a DNS confirmation for the wrong zone exits 1" 1 "$rc"
check_absent "nothing was destroyed" "destroy" "$commands"

run solzone/aws/us-east-1 --confirm --confirm-dns-zone sol.example.test
check "a fully confirmed uninstall exits 0" 0 "$rc"
check_contains \
  "the result reports the removals as observed absent" \
  "Removed and independently observed absent" \
  "$output"
check_contains "the result reports what was retained" "Retained:" "$output"
check_contains \
  "the operator-created identities are retained" \
  "provisioning identity -- the durable root does not create it" \
  "$output"
check_contains "the destroy ran" "destroy" "$commands"
check_contains "the state backend was released from state" "state rm aws_s3_bucket.state" "$commands"
check_contains \
  "the state backend was retired at the provider" \
  "s3api delete-bucket --bucket sol-uninstall-tfstate" \
  "$(cat "$tmp/aws.log")"

release_line="$(grep -n 'state rm aws_s3_bucket.state' "$tmp/terraform.log" | head -n1 | cut -d: -f1)"
destroy_line="$(grep -n 'destroy' "$tmp/terraform.log" | head -n1 | cut -d: -f1)"
if [ -z "$release_line" ] || [ -z "$destroy_line" ] || [ "$release_line" -ge "$destroy_line" ]; then
  echo "test_uninstall_cli: the state backend was not released before the destroy" >&2
  cat "$tmp/terraform.log" >&2
  fail=1
fi

run userzone/aws/us-east-1 --confirm
check "a target whose zone is the operator's needs no DNS confirmation and exits 0" 0 "$rc"
check_absent "the zone is not in the removal list" "remove  delegated DNS zone" "$output"
check_contains \
  "the result names the zone as retained" \
  "retain  user.example.test" \
  "$output"
check_contains \
  "the zone was taken out of the state" \
  "state rm aws_route53_zone.qualification[0]" \
  "$commands"

zone_line="$(grep -n 'state rm aws_route53_zone.qualification\[0\]' "$tmp/terraform.log" | head -n1 | cut -d: -f1)"
user_destroy_line="$(grep -n 'destroy' "$tmp/terraform.log" | head -n1 | cut -d: -f1)"
if [ -z "$zone_line" ] || [ -z "$user_destroy_line" ] || [ "$zone_line" -ge "$user_destroy_line" ]; then
  echo "test_uninstall_cli: the operator's zone was not taken out of state before the destroy" >&2
  cat "$tmp/terraform.log" >&2
  fail=1
fi

if [ "$fail" != 0 ]; then
  exit 1
fi
