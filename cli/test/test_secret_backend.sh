#!/bin/sh
set -eu
sol=$(realpath "$1")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
mkdir -p app/payments/charge_svc sol
printf 'FROM scratch\n' >app/payments/charge_svc/Dockerfile
printf 'project: secret-backend-test\nservices:\n  charge_svc:\n    type: http\n    path: app/payments/charge_svc\n    language: ocaml\n' >sol.yml
printf 'prod:\n  targets:\n    aws/us-east-1:\n      registry: registry.example.com\n      profile: production-single-region\n' >sol/environments.yml

# The deploy help must describe the operator-owned live Secret, not claim a
# direct deploy writes real values.
help=$("$sol" deploy --help=plain | tr '\n' ' ')
printf '%s\n' "$help" | grep -F 'operator-owned live Secret' >/dev/null
printf '%s\n' "$help" | grep -F 'sol secret set' >/dev/null

refuse() {
  label=$1
  shift
  if "$sol" "$@" >"$tmp/refused.out" 2>&1; then
    echo "sol accepted a secret-emission request it must refuse: $label" >&2
    cat "$tmp/refused.out" >&2
    exit 1
  fi
}

# external-secrets without its GitOps emission mode must refuse, not silently
# become a placeholder.
refuse "external-secrets without --emit-to" \
  deploy prod/aws/us-east-1 --secret-backend external-secrets
grep -F -- '--emit-to' "$tmp/refused.out" >/dev/null
if grep -F 'kubernetes-placeholder' "$tmp/refused.out" >/dev/null; then
  echo "the refusal silently selected kubernetes-placeholder" >&2
  cat "$tmp/refused.out" >&2
  exit 1
fi

# A missing store reference must refuse before any file output.
refuse "external-secrets without a store reference" \
  deploy prod/aws/us-east-1 --emit-to "$tmp/out" --secret-backend external-secrets
grep -F -- '--secret-store-ref is required' "$tmp/refused.out" >/dev/null
test ! -e "$tmp/out"

refuse "unknown store kind" \
  deploy prod/aws/us-east-1 --emit-to "$tmp/out" --secret-backend external-secrets \
  --secret-store-ref my-store --secret-store-kind ConfigMap
grep -F 'unknown secret store kind' "$tmp/refused.out" >/dev/null

refuse "malformed refresh interval" \
  deploy prod/aws/us-east-1 --emit-to "$tmp/out" --secret-backend external-secrets \
  --secret-store-ref my-store --refresh-interval soon
grep -F 'not a duration' "$tmp/refused.out" >/dev/null

refuse "irrelevant dependent flag" \
  deploy prod/aws/us-east-1 --secret-backend kubernetes-placeholder --secret-store-ref my-store
grep -F 'only apply with --secret-backend=external-secrets' "$tmp/refused.out" >/dev/null

refuse "unknown backend" deploy prod/aws/us-east-1 --secret-backend vault
grep -F 'unknown --secret-backend value' "$tmp/refused.out" >/dev/null

test ! -e "$tmp/out"
echo "secret emission options: refused before any output, and the help names live-secret ownership"
