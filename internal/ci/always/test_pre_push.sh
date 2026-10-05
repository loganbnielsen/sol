#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
hook="$root/internal/tooling/hooks/pre-push"
zero="0000000000000000000000000000000000000000"
fail=0

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

git -C "$fixture" init -q
git -C "$fixture" config user.email test@example.test
git -C "$fixture" config user.name test
mkdir -p "$fixture/internal/ci" "$fixture/internal/tooling/hooks"
cp "$hook" "$fixture/internal/tooling/hooks/pre-push"
cat >"$fixture/internal/ci/run_fast_checks.sh" <<'EOF'
#!/usr/bin/env bash
if grep -q bad checked.txt 2>/dev/null; then
  echo "fixture guard: checked.txt carries bad"
  exit 1
fi
echo "fixture guard: clean"
EOF
chmod +x "$fixture/internal/ci/run_fast_checks.sh"
printf 'good\n' >"$fixture/checked.txt"
git -C "$fixture" add -A
git -C "$fixture" commit -q -m init

run_hook() {
  local out="$1"
  shift
  local line="refs/heads/x $(git -C "$fixture" rev-parse HEAD) refs/heads/x $zero"
  ( cd "$fixture" && env "$@" bash internal/tooling/hooks/pre-push <<<"$line" ) >"$out" 2>&1
}

check() {
  local what="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "test_pre_push: $what: expected $expected, got $actual" >&2
    fail=1
  fi
}

check_contains() {
  local what="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *)
      echo "test_pre_push: $what: expected to find '$needle' in:" >&2
      echo "$haystack" >&2
      fail=1
      ;;
  esac
}

printf 'bad\n' >"$fixture/checked.txt"
run_hook "$fixture/out-dirty" && rc=0 || rc=$?
check "an unrelated dirty change does not block a clean pushed tip" 0 "$rc"
check_contains "the failure explains the dirt is excluded" "NOT part of the pushed tree" "$(cat "$fixture/out-dirty")"
check_contains "the committed tree is what got checked" "fixture guard: clean" "$(cat "$fixture/out-dirty")"

git -C "$fixture" add -A
git -C "$fixture" commit -q -m "carry the violation"
run_hook "$fixture/out-committed" && rc=0 || rc=$?
check "a violation in the pushed tip still blocks the push" 1 "$rc"
check_contains "the guards ran against the pushed tip" "fixture guard: checked.txt carries bad" "$(cat "$fixture/out-committed")"

run_hook "$fixture/out-escape" SOL_SKIP_PRE_PUSH=1 && rc=0 || rc=$?
check "the pre-push escape is enough on its own" 0 "$rc"

run_hook "$fixture/out-global" SOL_SKIP_HOOKS=1 && rc=0 || rc=$?
check "the global escape still works" 0 "$rc"

[ "$fail" = "0" ] && echo "test_pre_push: every expectation held."
exit "$fail"
