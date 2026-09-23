#!/usr/bin/env bash
# Offline state-machine test for live-qual.sh. Spends nothing: the external commands are
# stubs, so this asserts the HARNESS's behaviour — the sequence it drives, the arguments it
# renders, and what it does with the target file at each ending.
#
# Why this exists (Attempt 6): three harness defects were found by running it in anger, and
# one of them — `destroy_vars` deleted by a refactor — silently removed every variable from
# the teardown invocation while the code still read as correct. A refactor invalidates the
# evidence of a past green run; only an executable test of the affected path does not.
#
# argv assertions are the point, not a nicety: the harness constructs part of the effective
# configuration handed to Sol/Terraform. `create_dns_zone` was rendered `true` by an
# explicit override while the var-file said `false`, and each source looked reasonable in
# isolation. Asserting exit codes alone would have missed it entirely.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$HERE/live-qual.sh"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"

SCRATCH_WS="$TMP/workspace"
TARGET_FILE="$SCRATCH_WS/sol/qual/gcp/us-central1.yml"
mkdir -p "$SCRATCH_WS/sol/qual/gcp"
printf 'project: scratch\n' >"$SCRATCH_WS/sol.yml"
cleanup() {
  rm -f "$TARGET_FILE"
  # The harness creates the target's directory; removing the file alone leaves it behind and
  # the suite then reports the checkout dirty for a directory it made.
  rmdir "$(dirname "$TARGET_FILE")" 2>/dev/null || true
  [ "${KEEP_TMP:-0}" = "1" ] && { echo "kept: $TMP"; return; }
  rm -rf "$TMP"
}
trap cleanup EXIT


pass=0
fail=0
ok() { printf '  [OK]   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  [FAIL] %s\n           expected: %s\n           actual:   %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$3" "$2"; fi; }
has() { if grep -qF -- "$2" "$3"; then ok "$1"; else no "$1" "contains: $2" "$(tr '\n' '|' <"$3" | cut -c1-160)"; fi; }
lacks() { if grep -qF -- "$2" "$3"; then no "$1" "absent: $2" "present"; else ok "$1"; fi; }

# ── stubs ────────────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"

cat >"$TMP/bin/sol" <<'STUB'
#!/usr/bin/env bash
printf 'sol %s\n' "$*" >>"$ARGV_LOG"
case "$1 $2" in
  "cloud apply")   [ "${STUB_APPLY_RC:-0}" = "0" ] ;;
  "cloud destroy") [ "${STUB_DESTROY_RC:-0}" = "0" ] ;;
  "deploy")        printf 'deploy %s\n' "$*" >>"$ARGV_LOG"; [ "${STUB_DEPLOY_RC:-0}" = "0" ] ;;
  *) : ;;
esac
STUB

cat >"$TMP/bin/terraform" <<'STUB'
#!/usr/bin/env bash
printf 'terraform %s\n' "$*" >>"$ARGV_LOG"
# init/apply succeed; a -detailed-exitcode plan reports "no changes" so reconciliation is a
# no-op and the run does not depend on plan diffing for these assertions.
for a in "$@"; do [ "$a" = "plan" ] && exit "${STUB_PLAN_RC:-0}"; done
exit 0
STUB

cat >"$TMP/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
printf "gcloud %s" "$*" >>"$ARGV_LOG"; printf "\n" >>"$ARGV_LOG"
case "$*" in
  *"storage buckets describe"*) exit 0 ;;
  *"dns managed-zones"*)        printf "qual-gcp-sol-fab-dev\n"; exit 0 ;;
  *"compute regions describe"*) printf "CPUS;IN_USE_ADDRESSES;SSD_TOTAL_GB;DISKS_TOTAL_GB;INSTANCES,0;0;0;0;0\n"; exit 0 ;;
  *"compute networks list"*)    printf "default\n"; exit 0 ;;
esac
# STUB_TARGET_PRESENT=1 is the world where teardown did not finish.
if [ "${STUB_TARGET_PRESENT:-0}" = "1" ]; then
  case "$*" in *list* | *describe*) printf "test-cluster\n"; exit 0 ;; esac
fi
# Only the provider's own not-found vocabulary means ABSENT. Everything else is UNKNOWN,
# and UNKNOWN must fail the verification -- including shapes a future reader might be
# tempted to treat as absence (permission denied is the classic one).
case "${STUB_PROBE_MODE:-notfound}" in
  permission) printf "ERROR: (gcloud) The caller does not have permission\n" >&2; exit 1 ;;
  unknown)    printf "ERROR: (gcloud) transport layer gave up after 3 attempts\n" >&2; exit 1 ;;
  *)          printf "ERROR: (gcloud) NOT_FOUND: resource does not exist\n" >&2; exit 1 ;;
esac
STUB

cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '{"Answer":[{"data":"ns-cloud-c1.googledomains.com."},{"data":"ns-cloud-c2.googledomains.com."},{"data":"ns-cloud-c3.googledomains.com."},{"data":"ns-cloud-c4.googledomains.com."}]}'
STUB

cat >"$TMP/bin/dig" <<'STUB'
#!/usr/bin/env bash
printf 'qual-gcp.sol-fab.dev.\t3600\tIN\tNS\tns-cloud-c1.googledomains.com.\n'
STUB

chmod +x "$TMP"/bin/*

# ── the runner ───────────────────────────────────────────────────────────────
run_case() { # run_case <name> <subcommand> [VAR=VALUE ...]
  local name="$1" sub="$2"
  shift 2
  export ARGV_LOG="$TMP/$name.argv"
  export LOG_DIR="$TMP/$name.logs"
  # Scratch workspace: the harness writes the target file into it, so the repository is never
  # touched and "nothing was left behind" is an assertion about scratch, not a hope.
  export WORKSPACE="$SCRATCH_WS"
  : >"$ARGV_LOG"
  rm -f "$TARGET_FILE"
  rm -rf "$LOG_DIR"
  env ALLOW_CANONICAL=1 SOL="$TMP/bin/sol" CLUSTER=test-cluster \
    IMPERSONATOR=user:test@example.com LE_EMAIL=test@example.com \
    PATH="$TMP/bin:$PATH" "$@" \
    "$HARNESS" "$sub" >"$TMP/$name.out" 2>&1
  echo "$?" >"$TMP/$name.rc"
}

# ── 1. a successful cloud run keeps the target; teardown is a separate, deliberate act ──
printf '\nscenario: cloud succeeds\n'
run_case cloud-ok cloud
is "exit 0" "$(cat "$TMP/cloud-ok.rc")" "0"
lacks "no destroy on the success path (the delegation boundary keeps the substrate)" "cloud destroy" "$TMP/cloud-ok.argv"
has "the target is written for the run" "cluster_name" "$TARGET_FILE"

# ── 2. teardown: exactly once, correct variables, target removed only after verification ──
printf '\nscenario: destroy\n'
run_case destroy-ok destroy
is "exit 0" "$(cat "$TMP/destroy-ok.rc")" "0"
is "teardown is invoked" "$([ "$(grep -c 'cloud destroy' "$TMP/destroy-ok.argv")" -ge 1 ] && echo yes)" "yes"
# OPEN HARNESS DEFECT (found by this suite, not by reading code): the count is 2, and the two
# invocations are BYTE-IDENTICAL -- same subcommand, same variables. The run ended verified
# (exit 0, target removed, every postcondition checked), so a failure-retry cannot explain
# the second one, and an unconditional teardown at EXIT is the shape that fits. Not yet
# localized. Left red deliberately: a teardown invoked twice is the class of thing this
# suite exists to catch, and relaxing the assertion would have hidden it.
is "teardown is invoked exactly once" "$(grep -c 'cloud destroy' "$TMP/destroy-ok.argv")" "1"
has "destroy carries the cluster" "--var=cluster_name=test-cluster" "$TMP/destroy-ok.argv"
has "destroy carries the base domain" "--var=base_domain=" "$TMP/destroy-ok.argv"
has "destroy carries the impersonator" "provisioner_impersonators" "$TMP/destroy-ok.argv"
# The DEC-043 assertion: the durable zone is never handed to the disposable destroy.
lacks "the durable zone is not passed as disposable intent" "--var=create_dns_zone=true" "$TMP/destroy-ok.argv"
has "the durable zone is explicitly excluded" "--var=create_dns_zone=false" "$TMP/destroy-ok.argv"
if [ -f "$TARGET_FILE" ]; then no "the target is removed after verified teardown" "removed" "still present"; else ok "the target is removed after verified teardown"; fi

# ── 3. verification failure retains the target and exits non-zero ────────────
printf '\nscenario: verification finds a leftover\n'
run_case destroy-leftover destroy STUB_TARGET_PRESENT=1
if [ "$(cat "$TMP/destroy-leftover.rc")" = "0" ]; then no "non-zero exit when resources remain" "non-zero" "0"; else ok "non-zero exit when resources remain"; fi
if [ -f "$TARGET_FILE" ]; then ok "the target is retained when teardown is unverified"; else no "the target is retained when teardown is unverified" "present" "removed"; fi

# ── 4. a failed apply still tears down, and never reaches the platform ───────
printf '\nscenario: apply fails\n'
run_case cloud-fail cloud STUB_APPLY_RC=1
has "a failed apply still tears down" "cloud destroy" "$TMP/cloud-fail.argv"
lacks "a failed apply never reaches the platform" "deploy" "$TMP/cloud-fail.argv"
if [ "$(cat "$TMP/cloud-fail.rc")" = "0" ]; then no "a failed apply exits non-zero" "non-zero" "0"; else ok "a failed apply exits non-zero"; fi

# ── 5. UNKNOWN is not absence: both shapes pinned, separately ────────────────
# Mandatory evidence for the probe_gone fix. Only explicit provider not-found evidence
# establishes absence; pinning one unreadable shape and not the other invites the
# implementation to drift into an allowlist of errors that get called absence.
for mode in permission unknown; do
  printf '\nscenario: absence probe unreadable (%s)\n' "$mode"
  run_case "probe-$mode" destroy "STUB_PROBE_MODE=$mode"
  if [ "$(cat "$TMP/probe-$mode.rc")" = "0" ]; then
    no "an unreadable probe ($mode) fails the verification" "non-zero" "0"
  else
    ok "an unreadable probe ($mode) fails the verification"
  fi
  if grep -q 'could NOT determine absence' "$TMP/probe-$mode.out"; then
    ok "it names the failure to determine absence ($mode)"
  else
    no "it names the failure to determine absence ($mode)" "named" "unmentioned"
  fi
  if [ -f "$TARGET_FILE" ]; then
    ok "the target is retained ($mode)"
  else
    no "the target is retained ($mode)" "present" "removed"
  fi
done

# ── 6. one authoritative input for create_dns_zone, across every invocation ──
printf '\nscenario: no contradictory configuration is ever rendered\n'
if cat "$TMP"/*.argv | grep -qE 'create_dns_zone=true'; then
  no "no invocation asks for the durable zone to be created" "no create_dns_zone=true" "rendered somewhere"
else
  ok "no invocation asks for the durable zone to be created"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ] || exit 1
# Only leftovers matter: the harness writes the target file and its directory, and the
# person running this suite is usually mid-edit on the scripts themselves. Flagging those
# would make the suite fail for the developer's own working state.
dirty="$(git -C "$REPO" status --porcelain --untracked-files=all -- examples/pluto/)"
if [ -n "$dirty" ]; then
  printf '[FAIL] the suite left the checkout dirty:\n%s\n' "$dirty"; exit 1
fi
printf 'checkout clean\n'
