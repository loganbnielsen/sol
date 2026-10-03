#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_provider_roots.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkrepo() {
  rm -rf "$tmp/repo"
  for p in aws gcp; do
    for role in bootstrap cluster platform authorization; do
      mkdir -p "$tmp/repo/platform/cloud/$p/$role"
      echo '# fixture' >"$tmp/repo/platform/cloud/$p/$role/main.tf"
    done
  done
  mkdir -p "$tmp/repo/platform/cloud/modules/platform" "$tmp/repo/platform/cloud/delivery/ci"
}

failures=0
report_mismatch() {
  printf '  [FAIL] %s (%s)\n' "$1" "$2" >&2
  printf '%s\n' "$3" | sed 's/^/         /' >&2
  failures=$((failures + 1))
}

guard() {
  if GUARD_OUT="$(SOL_PROVIDERS="$1" "$CHECK" "$tmp/repo" 2>&1)"; then GUARD_GOT=pass; else GUARD_GOT=fail; fi
}

expect() {
  local want="$1" name="$2" providers="$3"
  guard "$providers"
  if [ "$GUARD_GOT" != "$want" ]; then
    report_mismatch "$name" "expected $want, got $GUARD_GOT" "$GUARD_OUT"
    exit 1
  fi
  echo "  [OK]   $name"
}

expect_refusal() {
  local needle="$1" name="$2" providers="$3"
  guard "$providers"
  if [ "$GUARD_GOT" != "fail" ]; then
    report_mismatch "$name" "expected a refusal, got a pass" "$GUARD_OUT"
    exit 1
  fi
  case "$GUARD_OUT" in
    *"$needle"*) echo "  [OK]   $name" ;;
    *)
      report_mismatch "$name" "refused, but not for '$needle'" "$GUARD_OUT"
      exit 1
      ;;
  esac
}

present=$'aws\tpresent\ngcp\tpresent'

mkrepo
expect pass "two providers with every role" "$present"

mkrepo
expect pass "a registered provider with no directory is on paper (S11)" "$present"$'\nazure\tnot_implemented'

mkrepo
expect pass "a rootless-by-definition driver with no directory" "$present"$'\nbyo\tnot_applicable'

mkrepo
mkdir -p "$tmp/repo/platform/cloud/byo/cluster"
echo '# fixture' >"$tmp/repo/platform/cloud/byo/cluster/main.tf"
expect fail "a rootless-by-definition driver that has a directory" "$present"$'\nbyo\tnot_applicable'

mkrepo
rm -rf "$tmp/repo/platform/cloud/aws"
expect fail "a driver that declares a root but has none" "$present"

mkrepo
rm -rf "$tmp/repo/platform/cloud/gcp/bootstrap"
expect fail "a provider with a directory but a missing role" "$present"

mkrepo
rm -f "$tmp/repo/platform/cloud/gcp/cluster/main.tf"
expect fail "a role directory with no Terraform in it" "$present"

mkrepo
mkdir -p "$tmp/repo/platform/cloud/azure/cluster"
echo '# fixture' >"$tmp/repo/platform/cloud/azure/cluster/main.tf"
expect fail "an unregistered directory under platform/cloud/" "$present"

mkrepo
mkdir -p "$tmp/repo/platform/cloud/azure/cluster"
echo '# fixture' >"$tmp/repo/platform/cloud/azure/cluster/main.tf"
expect fail "a registered provider that is half built" "$present"$'\nazure\tnot_implemented'

mkrepo
rm -rf "$tmp/repo/platform/cloud/aws" "$tmp/repo/platform/cloud/gcp"
expect fail "no provider has roots at all" "$present"

mkrepo
expect fail "a partial provider list cannot pass" $'gcp\tpresent'

mkrepo
if env -u SOL_PROVIDERS "$CHECK" "$tmp/repo" >/dev/null 2>&1; then
  echo "  [FAIL] an unreadable provider list fails closed" >&2
  exit 1
fi
echo "  [OK]   an unreadable provider list fails closed"

"$CHECK" "$ROOT" >/dev/null
echo "  [OK]   the repository's own providers"

echo
echo "the guard refuses a provider list it cannot validate"
mkrepo
expect_refusal "not a well-formed set" "a row whose fields are space-separated" "$present"$'\nazure not_implemented'

mkrepo
expect_refusal "not a well-formed set" "a row with an unknown root_status" "$present"$'\nazure\tsomething_else'

mkrepo
expect_refusal "not a well-formed set" "a row with an empty provider name" "$present"$'\n\tnot_implemented'

mkrepo
expect_refusal "not a well-formed set" "a provider named twice" "$present"$'\naws\tpresent'

mkrepo
expect_refusal "not a well-formed set" "a list that is only whitespace" " "

echo
echo "the verdict does not depend on a helper that can fail"
hostile="$tmp/hostile"
mkdir -p "$hostile"
for tool in grep awk cut basename sed tr head ls; do
  printf '#!/usr/bin/env bash\necho "%s: refusing" >&2\nexit 1\n' "$tool" >"$hostile/$tool"
  chmod +x "$hostile/$tool"
done
mkrepo
if PATH="$hostile:$PATH" SOL_PROVIDERS="$present" "$CHECK" "$tmp/repo" >"$tmp/hostile.out" 2>&1; then
  echo "  [OK]   a failing grep/awk/cut/basename on PATH leaves the verdict unchanged"
else
  report_mismatch "a failing helper changed the verdict" "expected pass, got fail" "$(cat "$tmp/hostile.out")"
  exit 1
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "provider-roots guard: every expectation held."
  exit 0
fi
echo "provider-roots guard: $failures expectation(s) FAILED."
exit 1
