#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/scratch_repo.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_examples_self_contained.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkrepo() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/examples/app/sol/dev/aws"
  scratch_repo_init "$tmp/repo"
  printf 'target:\n  cluster_name: app-dev\n' >"$tmp/repo/examples/app/sol/dev/aws/us-east-1.yml"
  printf 'Fixtures live in internal/fixtures/.\n' >"$tmp/repo/examples/README.md"
}

commit() {
  git -C "$tmp/repo" add -A
  git -C "$tmp/repo" -c user.email=t@t -c user.name=t commit -qm x
}

expect() {
  local want="$1" name="$2"
  if "$CHECK" "$tmp/repo" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" != "$want" ]; then
    echo "  [FAIL] $name (expected $want, got $got)"
    exit 1
  fi
  echo "  [OK]   $name"
}

mkrepo
commit
expect pass "a self-contained example; a README mentioning internal/ is prose"

mkrepo
printf '  terraform_var_file: ../../../../../internal/qualification/aws/smoke-test.tfvars\n' \
  >>"$tmp/repo/examples/app/sol/dev/aws/us-east-1.yml"
commit
expect fail "a target that reaches into internal/"

mkrepo
printf '(rule (deps ../../internal/fixtures/x))\n' >"$tmp/repo/examples/app/dune"
commit
expect fail "a dune file that depends on internal/"

mkrepo
printf 'FROM scratch\nCOPY internal/tooling /x\n' >"$tmp/repo/examples/app/Dockerfile"
commit
expect fail "a Dockerfile that copies from internal/"

mkrepo
printf 'target:\n  kubeconfig: ~/.kube/sol-internal/config\n' \
  >"$tmp/repo/examples/app/sol/dev/aws/us-east-1.yml"
commit
expect pass "a path segment merely ending in 'internal' is not internal/"

"$CHECK" "$ROOT" >/dev/null
echo "  [OK]   the repository's own examples"
