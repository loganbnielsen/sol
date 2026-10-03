#!/usr/bin/env bash
set -euo pipefail

repo="${1:-$(git rev-parse --show-toplevel)}"
establish="$repo/internal/qualification/transport/establish.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin" "$work/state"

cat >"$work/bin/aws" <<'AWS'
#!/usr/bin/env bash
set -euo pipefail
state="${SOL_QUALIFY_TEST_STATE:?}"
case "$1 $2" in
  "sts get-caller-identity") echo 111122223333 ;;
  "iam create-role" | "iam put-role-policy") : ;;
  "eks describe-access-entry") [ -f "$state/entry" ] ;;
  "eks create-access-entry") touch "$state/entry" ;;
  "eks delete-access-entry") rm -f "$state/entry" "$state/wide" ;;
  "eks associate-access-policy") touch "$state/wide" "$state/associated" ;;
  "eks disassociate-access-policy") touch "$state/disassociated" ;;
  *) : ;;
esac
AWS

cat >"$work/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
state="${SOL_QUALIFY_TEST_STATE:?}"
if [ "${1:-}" = "--context" ]; then shift 2; fi
case "$1" in
  apply)
    [ -f "$state/wide" ] || exit 1
    if [ -f "$state/apply-noop" ]; then exit 0; fi
    touch "$state/role"
    ;;
  get)
    case "$2" in
      clusterrole) [ -f "$state/role" ] ;;
      pods) [ -f "$state/entry" ] && [ -f "$state/role" ] ;;
      secrets)
        if [ -f "$state/residual" ] || [ -f "$state/wide" ]; then
          echo charge-svc-secrets
        else
          echo "Error from server (Forbidden): secrets is forbidden" >&2
          exit 1
        fi
        ;;
      *) : ;;
    esac
    ;;
  auth)
    case "$2" in
      whoami)
        echo '{"status":{"userInfo":{"username":"arn:aws:sts::111122223333:assumed-role/sol-qualifier-transport/EKSGetTokenAuth","arn":"arn:aws:sts::111122223333:assumed-role/sol-qualifier-transport/EKSGetTokenAuth"}}}'
        ;;
      can-i)
        if [ -f "$state/entry" ] && [ -f "$state/role" ]; then echo yes; else echo no; fi
        ;;
      *) : ;;
    esac
    ;;
  *) : ;;
esac
KUBECTL

chmod +x "$work/bin/aws" "$work/bin/kubectl"
export PATH="$work/bin:$PATH"
export SOL_QUALIFY_TEST_STATE="$work/state"
export SOL_QUALIFIER_VERIFY_ATTEMPTS=2
export SOL_QUALIFIER_VERIFY_INTERVAL_S=0

failures=0
ok() { printf '  [OK]   %s\n' "$1"; }
bad() {
  printf '  [FAIL] %s\n' "$1"
  failures=$((failures + 1))
}

reset_state() {
  rm -rf "$work/state"
  mkdir -p "$work/state"
}

run_establish() {
  if "$establish" sol-qual-cluster sol-qualifier-transport us-east-1 pluto-payments >"$work/out" 2>&1; then
    status=0
  else
    status=$?
  fi
}

expect_exit() {
  if [ "$status" = "$1" ]; then ok "$2"; else bad "$2 (observed exit $status)"; fi
}

expect_file() {
  if [ -f "$2" ]; then ok "$1"; else bad "$1"; fi
}

expect_no_file() {
  if [ -f "$2" ]; then bad "$1"; else ok "$1"; fi
}

expect_text() {
  if grep -q "$1" "$work/out"; then ok "$2"; else bad "$2"; fi
}

echo "establish: the surface it declares is the surface it verifies"
reset_state
run_establish
expect_exit 0 "a narrow end state is accepted"
expect_file "the run opened the establishment window" "$work/state/associated"
expect_file "the access entry remains" "$work/state/entry"
expect_no_file "the cluster-admin window is closed" "$work/state/wide"
expect_no_file "the window is never closed by a disassociation" "$work/state/disassociated"
expect_text "verified the effective surface" "the verification is the reported evidence"

echo
echo "establish: a surface broader than declared is refused, and nothing broad is left behind"
reset_state
touch "$work/state/residual"
run_establish
expect_exit 1 "a residual broad grant fails establishment"
expect_no_file "the access entry is removed rather than left broad" "$work/state/entry"
expect_no_file "the cluster-admin window is closed" "$work/state/wide"
expect_no_file "the window is never closed by a disassociation" "$work/state/disassociated"
expect_text "broader than declared" "the refusal names what it observed"

echo
echo "establish: a manifest that did not take effect fails, with the window closed"
reset_state
touch "$work/state/apply-noop"
run_establish
expect_exit 1 "a transport that did not apply fails establishment"
expect_no_file "the cluster-admin window is closed" "$work/state/wide"
expect_no_file "the window is never closed by a disassociation" "$work/state/disassociated"
expect_text "could not apply the transport manifest" "the failure names the manifest"

echo
if [ "$failures" -eq 0 ]; then
  echo "qualification transport establishment: every expectation held."
  exit 0
fi
echo "qualification transport establishment: $failures expectation(s) FAILED."
exit 1
