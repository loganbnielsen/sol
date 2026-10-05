#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
hook="$root/internal/tooling/hooks/pre-push"
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
printf 'fast checks ran\n'
exit "${FIXTURE_RC:-0}"
EOF
chmod +x "$fixture/internal/ci/run_fast_checks.sh"
cp "$hook" "$fixture/internal/tooling/hooks/pre-push"
printf 'x\n' >"$fixture/file"
git -C "$fixture" add -A
git -C "$fixture" commit -q -m init

run_hook() {
  local out="$1"; shift
  ( cd "$fixture" && env "$@" bash internal/tooling/hooks/pre-push </dev/null ) >"$out" 2>&1
}

run_hook "$fixture/out-ok" && rc=0 || rc=$?
[ "$rc" = 0 ] || { echo "test_pre_push: fast checks success should pass" >&2; fail=1; }
grep -q "fast checks ran" "$fixture/out-ok" || { echo "test_pre_push: fast checks did not run" >&2; fail=1; }

run_hook "$fixture/out-fail" FIXTURE_RC=7 && rc=0 || rc=$?
[ "$rc" = 7 ] || { echo "test_pre_push: fast-check failure should propagate" >&2; fail=1; }

run_hook "$fixture/out-skip" SOL_SKIP_PRE_PUSH=1 FIXTURE_RC=7 && rc=0 || rc=$?
[ "$rc" = 0 ] || { echo "test_pre_push: skip should bypass checks" >&2; fail=1; }

[ "$fail" = 0 ] && echo "test_pre_push: every expectation held."
exit "$fail"
