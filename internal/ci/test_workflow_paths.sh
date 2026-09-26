#!/usr/bin/env bash
# Mutation test for check_workflow_paths.sh (REFAC-099): a filter entry naming
# something that is gone must fail, and live literal and glob entries must pass.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_workflow_paths.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A throwaway repository: one tracked file under examples/, one script.
mkrepo() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/.github/workflows" "$tmp/repo/examples/app" "$tmp/repo/scripts"
  git -C "$tmp/repo" init -q
  echo x >"$tmp/repo/examples/app/a.txt"
  echo x >"$tmp/repo/scripts/run.sh"
  git -C "$tmp/repo" add -A
  git -C "$tmp/repo" -c user.email=t@t -c user.name=t commit -qm init
}

workflow() {
  cat >"$tmp/repo/.github/workflows/w.yml" <<EOF
on:
  pull_request:
    paths:
$(for e in "$@"; do printf "      - '%s'\n" "$e"; done)
jobs: {}
EOF
}

pass() {
  local name="$1"
  shift
  mkrepo
  workflow "$@"
  if ! "$CHECK" "$tmp/repo" >/dev/null 2>&1; then
    echo "  [FAIL] $name"
    exit 1
  fi
  echo "  [OK]   $name"
}

fail() {
  local name="$1"
  shift
  mkrepo
  workflow "$@"
  if "$CHECK" "$tmp/repo" >/dev/null 2>&1; then
    echo "  [FAIL] $name"
    exit 1
  fi
  echo "  [OK]   $name"
}

pass "a live literal entry" 'scripts/run.sh'
pass "a live glob entry" 'examples/**'
pass "the workflow file itself" '.github/workflows/w.yml'
pass "a negated entry naming nothing is exempt" 'scripts/run.sh' '!gone/**'
fail "a literal entry for a moved file" 'cli/platform/scripts/run.sh'
fail "a glob whose directory is gone" 'cli/platform/**'
fail "a glob whose directory exists but matches nothing tracked" 'examples/**/*.ml'
fail "one dead entry among live ones" 'examples/**' 'scripts/gone.sh'

# A script the workflow invokes directly must be executable: this is the exit-126 bounce, which a
# local sweep that runs everything as `bash <script>` cannot see.
mode_case() { # mode_case <name> <mode> <expected: pass|fail>
  local name="$1" mode="$2" expect="$3"
  mkrepo
  cat >"$tmp/repo/.github/workflows/w.yml" <<'EOF'
on: pull_request
jobs:
  x:
    steps:
      - run: |
          internal/ci/guard.sh .
EOF
  mkdir -p "$tmp/repo/internal/ci"
  echo 'echo hi' >"$tmp/repo/internal/ci/guard.sh"
  chmod "$mode" "$tmp/repo/internal/ci/guard.sh"
  git -C "$tmp/repo" add -A
  git -C "$tmp/repo" -c user.email=t@t -c user.name=t commit -qm script
  local rc=0
  "$CHECK" "$tmp/repo" >/dev/null 2>&1 || rc=$?
  case "$expect" in
    fail) [ "$rc" -ne 0 ] || { echo "  [FAIL] $name"; exit 1; } ;;
    pass) [ "$rc" -eq 0 ] || { echo "  [FAIL] $name"; exit 1; } ;;
  esac
  echo "  [OK]   $name"
}

mode_case "a directly invoked script that is not executable" 644 fail
mode_case "a directly invoked script that is executable" 755 pass

# `bash <script>` needs no bit: only a direct invocation does.
mkrepo
cat >"$tmp/repo/.github/workflows/w.yml" <<'EOF'
on: pull_request
jobs:
  x:
    steps:
      - run: bash internal/ci/guard.sh
EOF
mkdir -p "$tmp/repo/internal/ci"
echo 'echo hi' >"$tmp/repo/internal/ci/guard.sh"
chmod 644 "$tmp/repo/internal/ci/guard.sh"
git -C "$tmp/repo" add -A
git -C "$tmp/repo" -c user.email=t@t -c user.name=t commit -qm sourced
if "$CHECK" "$tmp/repo" >/dev/null 2>&1; then
  echo "  [OK]   a script invoked through bash needs no executable bit"
else
  echo "  [FAIL] a script invoked through bash needs no executable bit"
  exit 1
fi

# The real repository must pass as it stands.
"$CHECK" "$ROOT" >/dev/null
echo "  [OK]   the repository's own workflows"
