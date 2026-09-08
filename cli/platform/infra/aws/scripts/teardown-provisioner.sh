#!/usr/bin/env bash
# Tears down everything setup-provisioner.sh creates: access key(s), the
# user, the policy attachment, and the policy itself. Best-effort (|| true
# throughout) — safe to re-run if a previous teardown partially failed.
#
#   PROFILE=my-admin-profile ./scripts/teardown-provisioner.sh
set -uo pipefail
cd "$(dirname "$0")/.."

PROFILE="${PROFILE:?Set PROFILE to an AWS CLI profile with IAM admin rights}"
USER_NAME="${USER_NAME:-sol-smoke-test-infra-provisioner}"
POLICY_NAME="${POLICY_NAME:-sol-smoke-test-infra}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)}"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

echo "==> Deleting access keys for ${USER_NAME}..."
for key in $(aws iam list-access-keys --user-name "$USER_NAME" --profile "$PROFILE" \
  --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
  aws iam delete-access-key --user-name "$USER_NAME" --access-key-id "$key" --profile "$PROFILE" || true
done

echo "==> Detaching policy from ${USER_NAME}..."
aws iam detach-user-policy --user-name "$USER_NAME" --policy-arn "$POLICY_ARN" --profile "$PROFILE" || true

echo "==> Deleting user ${USER_NAME}..."
aws iam delete-user --user-name "$USER_NAME" --profile "$PROFILE" || true

echo "==> Deleting non-default policy versions for ${POLICY_NAME}..."
# IAM refuses to delete a policy that has more than one version -- the
# default version is deleted along with the policy itself, but any
# others (accumulated by iterating on the policy with create-policy-version
# during a real dogfood run, DOGFOOD-011) must go first, or delete-policy
# below fails with DeleteConflict.
for v in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --profile "$PROFILE" \
  --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null); do
  aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v" --profile "$PROFILE" || true
done

echo "==> Deleting policy ${POLICY_NAME}..."
aws iam delete-policy --policy-arn "$POLICY_ARN" --profile "$PROFILE" || true

echo "==> Teardown complete."
echo "==> Remember to remove the [${USER_NAME}] block from your local"
echo "    ~/.aws/credentials by hand — that file is local-only, not an AWS"
echo "    resource, so this script doesn't touch it."
