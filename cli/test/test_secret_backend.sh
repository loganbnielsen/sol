#!/usr/bin/env bash
set -euo pipefail
sol=$(realpath "$1")
tmp="/tmp/sol-secret-authority-test-$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
mkdir -p app/payments/charge_svc sol
printf 'FROM scratch\n' >app/payments/charge_svc/Dockerfile
cat >sol.yml <<'EOF'
project: secret-authority-test
services:
  charge_svc:
    type: http
    path: app/payments/charge_svc
    language: ocaml
EOF
cat >sol/environments.yml <<'EOF'
prod:
  targets:
    aws/us-east-1:
      registry: registry.example.com
      kube_context: unavailable-but-explicit
      secrets:
        payments/charge_svc:
          POSTGRES_URL:
            authority: external
            store: vault-production
            key: postgres/production
          SOL_API_KEY:
            authority: sol
EOF

refuse_external() {
  local label="$1"
  shift
  if "$sol" "$@" >"$tmp/refused.out" 2>&1; then
    echo "sol accepted unsupported external delivery: $label" >&2
    cat "$tmp/refused.out" >&2
    exit 1
  fi
  if ! grep -F 'externally managed, but external secret delivery is not yet supported' \
    "$tmp/refused.out" >/dev/null; then
    cat "$tmp/refused.out" >&2
    exit 1
  fi
}

# Configuration establishes that the key is externally owned, but M1 has no
# external delivery. This refusal must precede rendering or writing GitOps
# manifests, even when the legacy selector requests the former ESO path.
refuse_external "GitOps" \
  deploy prod/aws/us-east-1 --emit-to "$tmp/external-out" --image-tag abc
test ! -e "$tmp/external-out"

# Secret CRUD resolves ownership before opening either non-interactive input.
if "$sol" secret set prod/aws/us-east-1 \
  payments/charge_svc/POSTGRES_URL --from-file "$tmp/not-a-secret" \
  >"$tmp/set-refused.out" 2>&1; then
  echo "sol secret set accepted an externally owned key" >&2
  exit 1
fi
grep -F 'externally managed' "$tmp/set-refused.out" >/dev/null
if grep -F 'could not read' "$tmp/set-refused.out" >/dev/null; then
  echo "sol secret set opened the input before resolving external ownership" >&2
  cat "$tmp/set-refused.out" >&2
  exit 1
fi

# The reserved platform scope accepts only target Job inputs. Reject an
# application-only default before attempting to open the supplied file.
if "$sol" secret set prod/aws/us-east-1 @platform/SOL_API_KEY \
  --from-file "$tmp/not-a-secret" >"$tmp/platform-refused.out" 2>&1; then
  echo "sol secret set accepted an unsupported platform key" >&2
  exit 1
fi
grep -F 'not required by this target' "$tmp/platform-refused.out" >/dev/null
if grep -F 'could not read' "$tmp/platform-refused.out" >/dev/null; then
  echo "sol secret set opened platform input before resolving its scope" >&2
  cat "$tmp/platform-refused.out" >&2
  exit 1
fi

refuse_external "dry run" deploy prod/aws/us-east-1 --dry-run --image-tag abc

refuse_external "direct apply" deploy prod/aws/us-east-1 --image-tag abc

# The old backend selector cannot enable the not-yet-implemented ESO path for
# otherwise Sol-owned keys.
sed -i 's/authority: external/authority: sol/' sol/environments.yml
if "$sol" deploy prod/aws/us-east-1 --emit-to "$tmp/legacy-out" --image-tag abc \
  --secret-backend external-secrets --secret-store-ref vault-production \
  >"$tmp/backend-refused.out" 2>&1; then
  echo "sol accepted the pre-M2 external-secrets backend" >&2
  exit 1
fi
grep -F 'external secret delivery is not supported yet' "$tmp/backend-refused.out" >/dev/null
test ! -e "$tmp/legacy-out"

echo "secret authority: external keys fail closed on every M1 deployment path"
