#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/scratch_repo.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_workflow_paths.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkrepo() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/.github/workflows" "$tmp/repo/examples/app" "$tmp/repo/scripts"
  scratch_repo_init "$tmp/repo"
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
  if ! python3 "$CHECK" "$tmp/repo" >/dev/null 2>&1; then
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
  if python3 "$CHECK" "$tmp/repo" >/dev/null 2>&1; then
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

mode_case() {
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
  python3 "$CHECK" "$tmp/repo" >/dev/null 2>&1 || rc=$?
  case "$expect" in
    fail) [ "$rc" -ne 0 ] || { echo "  [FAIL] $name"; exit 1; } ;;
    pass) [ "$rc" -eq 0 ] || { echo "  [FAIL] $name"; exit 1; } ;;
  esac
  echo "  [OK]   $name"
}

mode_case "a directly invoked script that is not executable" 644 fail
mode_case "a directly invoked script that is executable" 755 pass

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
if python3 "$CHECK" "$tmp/repo" >/dev/null 2>&1; then
  echo "  [OK]   a script invoked through bash needs no executable bit"
else
  echo "  [FAIL] a script invoked through bash needs no executable bit"
  exit 1
fi

tool_case() {
  local name="$1" body="$2" expect="$3"
  mkrepo
  cat >"$tmp/repo/.github/workflows/w.yml" <<'EOF'
on: pull_request
jobs:
  x:
    steps:
      - run: internal/ci/guard.sh .
EOF
  mkdir -p "$tmp/repo/internal/ci"
  printf '%s\n' "$body" >"$tmp/repo/internal/ci/guard.sh"
  chmod 755 "$tmp/repo/internal/ci/guard.sh"
  git -C "$tmp/repo" add -A
  git -C "$tmp/repo" -c user.email=t@t -c user.name=t commit -qm tool
  local rc=0
  python3 "$CHECK" "$tmp/repo" >/dev/null 2>&1 || rc=$?
  case "$expect" in
    fail) [ "$rc" -ne 0 ] || { echo "  [FAIL] $name"; exit 1; } ;;
    pass) [ "$rc" -eq 0 ] || { echo "  [FAIL] $name"; exit 1; } ;;
  esac
  echo "  [OK]   $name"
}

tool_case "a CI-invoked script that calls rg" 'rg -n pattern file' fail
tool_case "a CI-invoked script that calls grep" 'grep -n pattern file' pass
tool_case "a CI-invoked script that merely mentions rg in a word" 'echo argos' pass

python3 "$CHECK" "$ROOT" >/dev/null
echo "  [OK]   the repository's own workflows"
