#!/usr/bin/env bash
set -uo pipefail

repo="${1:-$(git rev-parse --show-toplevel)}"
script="$repo/internal/tooling/scripts/bump-support-refs.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state"

cat >"$work/bin/git" <<'GIT'
#!/usr/bin/env bash
state="${BUMP_TEST_STATE:?}"
if [ "${1:-}" = "ls-remote" ]; then
  name="$(printf '%s' "${2:-}" | tr -c 'a-zA-Z0-9' '_')"
  [ -f "$state/fail-$name" ] && exit 128
  [ -f "$state/sha-$name" ] && cat "$state/sha-$name"
  exit 0
fi
if [ "${1:-}" = "-C" ]; then
  [ -f "$state/opam-files" ] && cat "$state/opam-files"
  exit 0
fi
exit 0
GIT
chmod +x "$work/bin/git"

old_kafka="1111111111111111111111111111111111111111"
new_kafka="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
old_pg="2222222222222222222222222222222222222222"
new_pg="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
kafka_url="https://example.invalid/kafka-eio.git"
pg_url="https://example.invalid/pg-eio.git"

root="$work/root"
root_state="$work/state"
failures=0
ok() { printf '  [OK]   %s\n' "$1"; }
bad() {
  printf '  [FAIL] %s\n' "$1"
  failures=$((failures + 1))
}

setup() {
  rm -rf "$root" "$root_state"
  mkdir -p "$root" "$root_state"
  printf 'kafka-eio %s %s\npg-eio %s %s\n' "$kafka_url" "$old_kafka" "$pg_url" "$old_pg" \
    >"$root/support-refs.txt"
  printf 'pin-depends: [ "git+https://example.invalid/kafka-eio.git#%s" ]\n' "$old_kafka" >"$root/sol-fn.opam"
  printf 'pin-depends: [ "git+https://example.invalid/pg-eio.git#%s" ]\n' "$old_pg" >"$root/sol-svc.opam"
  printf 'sol-fn.opam\nsol-svc.opam\n' >"$root_state/opam-files"
  printf '%s' "$new_kafka" >"$root_state/sha-$(printf '%s' "$kafka_url" | tr -c 'a-zA-Z0-9' '_')"
  printf '%s' "$new_pg" >"$root_state/sha-$(printf '%s' "$pg_url" | tr -c 'a-zA-Z0-9' '_')"
}

run_bump() {
  if PATH="$work/bin:$PATH" BUMP_TEST_STATE="$root_state" SUPPORT_ROOT="$root" \
    "$script" "$@" >"$work/out" 2>&1; then
    status=0
  else
    status=$?
  fi
}

contains() {
  if grep -qF "$2" "$1"; then ok "$3"; else bad "$3"; fi
}

lacks() {
  if grep -qF "$2" "$1"; then bad "$3"; else ok "$3"; fi
}

expect_exit() {
  if [ "$status" = "$1" ]; then ok "$2"; else bad "$2 (observed exit $status)"; fi
}

echo "support-refs bump: a resolution failure writes nothing"
setup
rm -f "$root_state/sha-$(printf '%s' "$pg_url" | tr -c 'a-zA-Z0-9' '_')"
printf '1' >"$root_state/fail-$(printf '%s' "$pg_url" | tr -c 'a-zA-Z0-9' '_')"
run_bump
expect_exit 1 "a failed resolution exits non-zero"
contains "$work/out" "cannot resolve main of pg-eio" "the failure names the package"
contains "$root/support-refs.txt" "$old_kafka" "the reference list keeps the old kafka-eio commit"
contains "$root/support-refs.txt" "$old_pg" "the reference list keeps the old pg-eio commit"
contains "$root/sol-fn.opam" "$old_kafka" "no opam pin was rewritten before the failure"

echo
echo "support-refs bump: the whole set is applied together"
setup
run_bump
expect_exit 0 "a complete resolution succeeds"
contains "$root/support-refs.txt" "$new_kafka" "the reference list takes the new kafka-eio commit"
contains "$root/support-refs.txt" "$new_pg" "the reference list takes the new pg-eio commit"
contains "$root/sol-fn.opam" "$new_kafka" "the kafka-eio pin follows"
contains "$root/sol-svc.opam" "$new_pg" "the pg-eio pin follows"
lacks "$root/sol-fn.opam" "$old_kafka" "the previous kafka-eio pin is gone"

echo
echo "support-refs bump: an unknown package is refused"
setup
cp "$root/support-refs.txt" "$work/before-refs"
cp "$root/sol-fn.opam" "$work/before-opam"
run_bump not-a-package
expect_exit 1 "an unknown requested package exits non-zero"
contains "$work/out" "no support reference named 'not-a-package'" "the refusal names the package"
if cmp -s "$root/support-refs.txt" "$work/before-refs"; then ok "the reference list is unchanged"; else bad "the reference list is unchanged"; fi
if cmp -s "$root/sol-fn.opam" "$work/before-opam"; then ok "the opam pins are unchanged"; else bad "the opam pins are unchanged"; fi

echo
echo "support-refs bump: a failed write leaves the original set"
setup
chmod a-w "$root/support-refs.txt"
run_bump
chmod u+w "$root/support-refs.txt"
expect_exit 1 "a write failure exits non-zero"
contains "$work/out" "cannot write" "the failure names the write"
contains "$root/sol-fn.opam" "$old_kafka" "the kafka-eio pin was restored"
contains "$root/sol-svc.opam" "$old_pg" "the pg-eio pin was restored"
contains "$root/support-refs.txt" "$old_kafka" "the reference list still holds the old set"

echo
if [ "$failures" -eq 0 ]; then
  echo "support-refs bump: every expectation held."
  exit 0
fi
echo "support-refs bump: $failures expectation(s) FAILED."
exit 1
