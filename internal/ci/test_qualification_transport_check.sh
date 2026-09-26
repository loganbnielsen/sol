#!/usr/bin/env bash
set -euo pipefail

# DEC-039 / FND-0020: proves check_qualification_transport.sh can fail.
#
# Each case breaks exactly one property and requires rejection -- including the two
# that would be silent in review: a production root acquiring the capability, and
# the transport quietly gaining a verb that makes it a mutation identity.

repo="${1:-$(git rev-parse --show-toplevel)}"
guard="$repo/internal/ci/check_qualification_transport.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

seed() {
  rm -rf "$work/root"
  mkdir -p "$work/root/internal/pipeline/qualification/transport" \
           "$work/root/internal/ci" \
           "$work/root/cli/lib" \
           "$work/root/platform/cloud/modules/platform"
  cp "$repo/internal/pipeline/qualification/transport/transport.yaml" \
     "$work/root/internal/pipeline/qualification/transport/transport.yaml"
  cp "$repo/internal/pipeline/qualification/transport/establish.sh" \
     "$work/root/internal/pipeline/qualification/transport/establish.sh"
  cp "$repo/cli/lib/sol_cli_config.ml" "$work/root/cli/lib/sol_cli_config.ml"
  printf '# production root\n' > "$work/root/platform/cloud/modules/platform/main.tf"
}

expect_pass() {
  if ! bash "$guard" "$work/root" >"$work/out" 2>&1; then
    echo "test_qualification_transport: expected the guard to pass, but it failed:" >&2
    cat "$work/out" >&2
    exit 1
  fi
}

expect_fail() {
  if bash "$guard" "$work/root" >"$work/out" 2>&1; then
    echo "test_qualification_transport: the guard accepted $1" >&2
    exit 1
  fi
}

seed
expect_pass

# ── the transport gains a mutating verb ─────────────────────────────────────
seed
sed -i 's/    verbs: \["create"\]/    verbs: ["create", "delete"]/' \
  "$work/root/internal/pipeline/qualification/transport/transport.yaml"
expect_fail "a mutating verb in the transport"

# ── the transport gains exec ────────────────────────────────────────────────
seed
sed -i 's/    resources: \["pods\/portforward"\]/    resources: ["pods\/portforward", "pods\/exec"]/' \
  "$work/root/internal/pipeline/qualification/transport/transport.yaml"
expect_fail "pods/exec in the transport"

# ── the transport gains events (observation, not transport) ─────────────────
seed
sed -i 's/    resources: \["pods", "services"\]/    resources: ["pods", "services", "events"]/' \
  "$work/root/internal/pipeline/qualification/transport/transport.yaml"
expect_fail "events in the transport"

# ── the transport loses its reason to exist ─────────────────────────────────
seed
sed -i 's/    resources: \["pods\/portforward"\]/    resources: ["pods"]/' \
  "$work/root/internal/pipeline/qualification/transport/transport.yaml"
expect_fail "a transport without portforward"

# ── a production root acquires the capability ───────────────────────────────
seed
printf 'resource "kubernetes_cluster_role_binding" "leak" {\n  subject { name = "sol:qualifiers" }\n}\n' \
  > "$work/root/platform/cloud/modules/platform/leak.tf"
expect_fail "a production root referencing the qualifier group"

# ── the customer-facing contract names the qualifier ────────────────────────
seed
printf '\nlet qualifier_role_arn = None\n' >> "$work/root/cli/lib/sol_cli_config.ml"
expect_fail "a qualifier principal in the target schema"

echo "qualification transport check: every guard rejection reproduced"
