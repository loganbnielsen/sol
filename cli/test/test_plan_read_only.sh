#!/usr/bin/env bash
set -eu

sol="$(realpath "$1")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/workspace/app/payments/api_svc" "$tmp/workspace/app/payments/events_worker" "$tmp/workspace/sol" "$tmp/bin"
printf 'FROM scratch\n' > "$tmp/workspace/app/payments/api_svc/Dockerfile"
printf 'FROM scratch\n' > "$tmp/workspace/app/payments/events_worker/Dockerfile"
cat > "$tmp/workspace/sol.yml" <<'EOF'
project: plan_test
services:
  api_svc:
    language: ocaml
  events_worker:
    language: ocaml
EOF
cat > "$tmp/workspace/sol/environments.yml" <<'EOF'
prod:
  targets:
    aws/us-east-1:
      cluster_name: planned
      kube_context: planned
      state_bucket: sol-plan-state
      aws:
        state_lock_table: sol-plan-lock
EOF
cat > "$tmp/bin/terraform" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/terraform.log"
exit 0
EOF
cat > "$tmp/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo 'ResourceNotFound: not found' >&2
exit 1
EOF
cat > "$tmp/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo 'Unable to connect to the server: dial tcp 192.0.2.1:443: i/o timeout' >&2
exit 1
EOF
chmod +x "$tmp/bin/terraform" "$tmp/bin/aws" "$tmp/bin/kubectl"
cd "$tmp/workspace"
PATH="$tmp/bin:$PATH" "$sol" plan prod/aws/us-east-1 \
  --image-ref api_svc=registry.example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --image-ref events_worker=registry.example/worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  > "$tmp/output"
grep -F 'image=registry.example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$tmp/output" >/dev/null
grep -F 'image=registry.example/worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$tmp/output" >/dev/null
grep -F 'First-run installation bootstrap plan (temporary local state)' "$tmp/output" >/dev/null
grep -F 'init -backend=false' "$tmp/terraform.log" >/dev/null
grep -F ' plan ' "$tmp/terraform.log" >/dev/null
terraform_chdir=$(sed -n '1s/.*-chdir=\([^ ]*\).*/\1/p' "$tmp/terraform.log")
test -n "$terraform_chdir"
test ! -e "$terraform_chdir"
if grep -F ' apply ' "$tmp/terraform.log" >/dev/null; then
  echo 'sol plan invoked terraform apply' >&2
  exit 1
fi
if PATH="$tmp/bin:$PATH" "$sol" plan prod/aws/us-east-1 \
  --image-ref api_svc=registry.example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  > "$tmp/unreachable-output" 2>&1; then
  echo 'sol plan unexpectedly inherited images from an unreachable cluster' >&2
  exit 1
fi
grep -F 'cannot inherit workload images from the current release' "$tmp/unreachable-output" >/dev/null
