#!/usr/bin/env bash
# Provisions the IAM identity used to run `terraform apply`/`destroy` against
# platform/infra/aws/main.tf (typically with smoke-test.tfvars). Creates a
# scoped IAM policy from smoke-test-iam-policy.json, a new IAM user, attaches
# the policy, and writes a new profile to your local ~/.aws/credentials —
# never prints the secret access key to stdout.
#
# Run once with an AWS CLI profile that has IAM admin rights (create
# user/policy, attach policy, create access key) — NOT the
# sts-smoke-test-user/sts-smoke-test-provisioner profiles used by s3-eio's
# live test; those stay scoped to that test only.
#
#   PROFILE=my-admin-profile ./scripts/setup-provisioner.sh
#
# Not idempotent — re-running against an already-existing user/policy will
# fail; run teardown-provisioner.sh first if you need to recreate it.
#
# smoke-test-iam-policy.json is minified with terse Sids on purpose: AWS
# managed policies have a hard 6144-byte document limit, and this policy
# (covering VPC/EKS/RDS/ECR/KMS/IAM-for-IRSA end to end) sits close enough
# to that ceiling that pretty-printing alone would exceed it. Don't
# reformat it "for readability" without checking the resulting byte count
# (`python3 -c "import json;print(len(open('smoke-test-iam-policy.json').read()))"`)
# — verified against a real DOGFOOD-011 apply+destroy cycle at this size;
# see project/dogfood/ for the run that shaped every statement in it.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${PROFILE:?Set PROFILE to an AWS CLI profile with IAM admin rights}"
USER_NAME="${USER_NAME:-sol-smoke-test-infra-provisioner}"
POLICY_NAME="${POLICY_NAME:-sol-smoke-test-infra}"

echo "==> Creating IAM policy ${POLICY_NAME}..."
POLICY_ARN="$(aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document file://smoke-test-iam-policy.json \
  --profile "$PROFILE" \
  --query 'Policy.Arn' --output text)"

echo "==> Creating IAM user ${USER_NAME}..."
aws iam create-user --user-name "$USER_NAME" --profile "$PROFILE" > /dev/null

echo "==> Attaching policy to ${USER_NAME}..."
aws iam attach-user-policy --user-name "$USER_NAME" --policy-arn "$POLICY_ARN" --profile "$PROFILE"

echo "==> Creating access key..."
creds="$(aws iam create-access-key --user-name "$USER_NAME" --profile "$PROFILE" \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)"
read -r ACCESS_KEY_ID SECRET_ACCESS_KEY <<<"$creds"

CRED_FILE="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
{
  echo ""
  echo "[${USER_NAME}]"
  echo "aws_access_key_id = ${ACCESS_KEY_ID}"
  echo "aws_secret_access_key = ${SECRET_ACCESS_KEY}"
} >> "$CRED_FILE"

echo "==> Wrote profile [${USER_NAME}] to ${CRED_FILE}."
echo "==> Policy ARN: ${POLICY_ARN}"
echo "==> Use with: AWS_PROFILE=${USER_NAME} AWS_REGION=us-east-1 terraform ..."
