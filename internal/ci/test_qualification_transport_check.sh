#!/usr/bin/env bash
set -euo pipefail

repo="${1:-$(git rev-parse --show-toplevel)}"
guard="$repo/internal/ci/check_qualification_transport.py"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

seed() {
  rm -rf "$work/root"
  mkdir -p "$work/root/internal/qualification/transport" \
           "$work/root/internal/ci" \
           "$work/root/cli/lib/workspace" \
           "$work/root/platform/cloud/modules/platform"
  cp "$repo/internal/qualification/transport/transport.yaml" \
     "$work/root/internal/qualification/transport/transport.yaml"
  cp "$repo/internal/qualification/transport/establish.sh" \
     "$work/root/internal/qualification/transport/establish.sh"
  cp "$repo/cli/lib/workspace/sol_cli_config.ml" "$work/root/cli/lib/workspace/sol_cli_config.ml"
  printf '# production root\n' > "$work/root/platform/cloud/modules/platform/main.tf"
}

expect_pass() {
  if ! python3 "$guard" "$work/root" >"$work/out" 2>&1; then
    echo "test_qualification_transport: expected the guard to pass, but it failed:" >&2
    cat "$work/out" >&2
    exit 1
  fi
}

expect_fail() {
  if python3 "$guard" "$work/root" >"$work/out" 2>&1; then
    echo "test_qualification_transport: the guard accepted $1" >&2
    exit 1
  fi
}

seed
expect_pass

seed
sed -i 's/    verbs: \["create"\]/    verbs: ["create", "delete"]/' \
  "$work/root/internal/qualification/transport/transport.yaml"
expect_fail "a mutating verb in the transport"

seed
sed -i 's/    resources: \["pods\/portforward"\]/    resources: ["pods\/portforward", "pods\/exec"]/' \
  "$work/root/internal/qualification/transport/transport.yaml"
expect_fail "pods/exec in the transport"

seed
sed -i 's/    resources: \["pods", "services"\]/    resources: ["pods", "services", "events"]/' \
  "$work/root/internal/qualification/transport/transport.yaml"
expect_fail "events in the transport"

seed
sed -i 's/    resources: \["pods\/portforward"\]/    resources: ["pods"]/' \
  "$work/root/internal/qualification/transport/transport.yaml"
expect_fail "a transport without portforward"

seed
printf 'resource "kubernetes_cluster_role_binding" "leak" {\n  subject { name = "sol:qualifiers" }\n}\n' \
  > "$work/root/platform/cloud/modules/platform/leak.tf"
expect_fail "a production root referencing the qualifier group"

seed
printf '\nlet qualifier_role_arn = None\n' >> "$work/root/cli/lib/workspace/sol_cli_config.ml"
expect_fail "a qualifier principal in the target schema"

seed
sed -i 's/\\"Resource\\":\\"\${cluster_arn}\\"/\\"Resource\\":\\"*\\"/' \
  "$work/root/internal/qualification/transport/establish.sh"
expect_fail "an inline policy scoped to every cluster"

seed
sed -i 's/\\"Action\\":\\"eks:DescribeCluster\\"/\\"Action\\":\\"eks:ListClusters\\"/' \
  "$work/root/internal/qualification/transport/establish.sh"
expect_fail "an inline policy granting a verb the transport does not use"

seed
printf '\naws eks disassociate-access-policy --cluster-name x --principal-arn y --policy-arn z\n' \
  >> "$work/root/internal/qualification/transport/establish.sh"
expect_fail "a window closed by disassociation"

echo "qualification transport check: every guard rejection reproduced"
