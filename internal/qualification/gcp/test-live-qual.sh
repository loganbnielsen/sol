#!/usr/bin/env bash
# Offline state-machine test for live-qual.sh. Spends nothing: the external commands are
# stubs, so this asserts the HARNESS's behaviour — the sequence it drives, the arguments it
# renders, the evidence it captures, and what it does with the target file at each ending.
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
#
# It also pins the attempt-8 re-scope's properties, because each of them is the kind of thing
# that silently regresses when someone edits the harness:
#   H1  the generated target asks for no TLS issuer (or the run stops before cert-manager);
#   H2  a failed `sol cloud apply` captures the discriminator BEFORE any teardown — asserted
#       by argv ORDER, so "capture moved after the destroy" fails rather than passes;
#   H3  both Terraform state snapshots are in the bundle;
#   H4  Sol's own run artifacts are copied out of its pruning window;
#   H5  the inventory is tri-state, covers the classes the contract names, and a failed read
#       is UNKNOWN — never ABSENT;
#   H6  a pre-teardown provider inventory is captured before anything is destroyed;
#   and the process discipline: identity-based stopping only, no pattern kills, no
#       force-unlock, durable resources never handed to the disposable destroy.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$HERE/live-qual.sh"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"

SCRATCH_WS="$TMP/workspace"
TARGET_FILE="$SCRATCH_WS/sol/environments.local.yml"
mkdir -p "$SCRATCH_WS/sol"
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
present() { if [ -s "$1" ]; then ok "$2"; else no "$2" "present and non-empty" "missing: $1"; fi; }

# ── stubs ────────────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"

cat >"$TMP/bin/sol" <<'STUB'
#!/usr/bin/env bash
printf 'sol %s\n' "$*" >>"$ARGV_LOG"
case "$1 $2" in
  "cloud apply")
    printf 'lifecycle phase: CloudBootstrap\n[terraform-apply] ok\n'
    printf 'lifecycle phase: PlatformInstalling\nplatform-apply ok\n'
    printf 'provisioner-bootstrap-access-remove ok\n'
    printf 'lifecycle phase: Ready\nDone.\n'
    [ "${STUB_APPLY_RC:-0}" = "0" ] ;;
  "cloud destroy") [ "${STUB_DESTROY_RC:-0}" = "0" ] ;;
  "deploy")        [ "${STUB_DEPLOY_RC:-0}" = "0" ] ;;
  *) : ;;
esac
STUB

cat >"$TMP/bin/terraform" <<'STUB'
#!/usr/bin/env bash
printf 'terraform %s\n' "$*" >>"$ARGV_LOG"
# A destructive reconcile: -detailed-exitcode reports "changes", and `show` renders the plan
# the harness must refuse rather than apply.
if [ "${STUB_PLAN_DESTROYS:-0}" = "1" ]; then
  for a in "$@"; do
    [ "$a" = "plan" ] && exit 2
    [ "$a" = "show" ] && { printf '# google_storage_bucket.state must be replaced\n'; exit 0; }
  done
fi
# init/apply succeed; a -detailed-exitcode plan reports "no changes" so reconciliation is a
# no-op and the run does not depend on plan diffing for these assertions.
for a in "$@"; do [ "$a" = "plan" ] && exit "${STUB_PLAN_RC:-0}"; done
exit 0
STUB

cat >"$TMP/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
printf "gcloud %s" "$*" >>"$ARGV_LOG"; printf "\n" >>"$ARGV_LOG"
case "$*" in
  *"storage buckets describe"*) printf "sol-qualification-tfstate\n"; exit 0 ;;
  *"storage cat"*)
    if [ "${STUB_STATE_UNREADABLE:-0}" = "1" ]; then
      printf "ERROR: (gcloud) The caller does not have permission\n" >&2; exit 1
    fi
    printf '{"version":4,"serial":7,"resources":[]}\n'; exit 0 ;;
  *"dns managed-zones describe"*) printf "qual-gcp-sol-fab-dev\n"; exit 0 ;;
  *"dns managed-zones"*)        printf "qual-gcp-sol-fab-dev\n"; exit 0 ;;
  # Real gcloud warns on stderr when a filtered list is empty; its stdout stays empty. The
  # probe must read that as ABSENT, not as an answer.
  *"compute addresses list"*)
    if [ "${STUB_FILTER_WARNING:-0}" = "1" ]; then
      printf "WARNING: The following filter keys were not present in any resource : name\n" >&2
    fi
    exit 0 ;;
  *"compute regions describe"*)
    if [ "${STUB_QUOTA_GARBAGE:-0}" = "1" ]; then printf "not a quota document\n"; exit 0; fi
    if [ "${STUB_QUOTA_BUSY:-0}" = "1" ]; then printf "CPUS;IN_USE_ADDRESSES;SSD_TOTAL_GB;DISKS_TOTAL_GB;INSTANCES,4;0;0;0;1\n"; exit 0; fi
    printf "CPUS;IN_USE_ADDRESSES;SSD_TOTAL_GB;DISKS_TOTAL_GB;INSTANCES,0;0;0;0;0\n"; exit 0 ;;
  *"compute networks list"*)    printf "default\n"; exit 0 ;;
esac
# ── the IAM observables (INFRA-080) ─────────────────────────────────────────────
# These are the questions the harness asks now, and the wording below is what GCP actually
# answered in Attempts 8 and 9: an authoritative active-account list, the identity's own
# policy, and the custom role's own deletion marker.
#
# `STUB_PROVISIONER_SA` is run_case's CLUSTER ("test-cluster") at the project the harness
# defaults to; the scenarios assert the harness asked about exactly this identity, so the
# fixture cannot drift away from it silently.
case "$*" in
  # The provisioner's own describe, in both worlds, with the wording Attempt 9 captured: an
  # active account answers with itself, and a provider-deleted one answers PERMISSION_DENIED
  # -- which establishes nothing, and is exactly why this class asks an authoritative list
  # instead. Other identities keep the generic not-found fallthrough below.
  *"iam service-accounts describe"*)
    case "$*" in
      *"$STUB_PROVISIONER_SA"*)
        if [ "${STUB_SA_ACTIVE_PROVISIONER:-0}" = "1" ]; then
          printf "%s\n" "$STUB_PROVISIONER_SA"; exit 0
        fi
        printf "ERROR: (gcloud.iam.service-accounts.describe) PERMISSION_DENIED: Permission 'iam.serviceAccounts.get' denied on resource (or it may not exist). This command is authenticated as test@example.com which is the active account specified by the [core/account] property.\n" >&2
        exit 1 ;;
    esac ;;
  *"iam service-accounts list"*)
    if [ "${STUB_SA_LIST_FAIL:-0}" = "1" ]; then
      printf "ERROR: (gcloud.iam.service-accounts.list) PERMISSION_DENIED: Permission 'iam.serviceAccounts.list' denied on resource.\n" >&2
      exit 1
    fi
    printf "819835583654-compute@developer.gserviceaccount.com\n"
    [ "${STUB_SA_ACTIVE_PROVISIONER:-0}" = "1" ] && printf "%s\n" "$STUB_PROVISIONER_SA"
    exit 0 ;;
  *"iam service-accounts get-iam-policy"*)
    case "${STUB_SA_POLICY:-denied}" in
      binding) printf "roles/iam.serviceAccountTokenCreator\n"; exit 0 ;;
      empty)   exit 0 ;;
      *)
        printf "ERROR: (gcloud.iam.service-accounts.get-iam-policy) PERMISSION_DENIED: Permission 'iam.serviceAccounts.getIamPolicy' denied on resource (or it may not exist). This command is authenticated as test@example.com which is the active account specified by the [core/account] property.\n" >&2
        exit 1 ;;
    esac ;;
  *"iam roles describe"*)
    case "${STUB_ROLE_STATE:-deleted}" in
      deleted)  printf "projects/sol-qualification/roles/sol_test_cluster_access\tTrue\n"; exit 0 ;;
      active)   printf "projects/sol-qualification/roles/sol_test_cluster_access\tFalse\n"; exit 0 ;;
      notfound) printf "ERROR: (gcloud.iam.roles.describe) NOT_FOUND: The role named projects/sol-qualification/roles/sol_test_cluster_access was not found.\n" >&2; exit 1 ;;
      *)        printf "ERROR: (gcloud.iam.roles.describe) PERMISSION_DENIED: The caller does not have permission\n" >&2; exit 1 ;;
    esac ;;
esac
# STUB_CLUSTER_EXISTS=1 is the world where the cloud apply reached the cluster (so the
# discriminator probes have something to read) without claiming the target still exists.
if [ "${STUB_CLUSTER_EXISTS:-0}" = "1" ]; then
  case "$*" in
    *"container clusters describe"* | *"container clusters get-credentials"*) printf "test-cluster\n"; exit 0 ;;
  esac
fi
# STUB_TARGET_PRESENT=1 is the world where teardown did not finish.
if [ "${STUB_TARGET_PRESENT:-0}" = "1" ]; then
  case "$*" in *list* | *describe*) printf "test-cluster\n"; exit 0 ;; esac
fi
# Only the provider's own not-found vocabulary means ABSENT; everything else is UNKNOWN and
# must fail the verification. These strings are the provider's **captured** output, verbatim --
# a paraphrase is how the underscore form went unnoticed (`NOT_FOUND: resource does not exist`
# matched the pattern through its `does not exist` alternative while the real
# `NOT_FOUND: Unknown service account` did not).
case "${STUB_PROBE_MODE:-notfound}" in
  permission)
    printf 'ERROR: (gcloud.projects.get-iam-policy) [lbendtlynielsen@gmail.com] does not have permission to access projects instance [cloud-sdk-dev:getIamPolicy] (or it may not exist): The caller does not have permission. This command is authenticated as lbendtlynielsen@gmail.com which is the active account specified by the [core/account] property\n' >&2
    exit 1 ;;
  transport)
    printf "ERROR: gcloud crashed (ConnectionError): HTTPSConnectionPool(host='127.0.0.1', port=1): Max retries exceeded with url: /compute/v1/projects/sol-qualification/global/networks?alt=json&maxResults=500 (Caused by NewConnectionError(\"HTTPSConnection(host='127.0.0.1', port=1): Failed to establish a new connection: [Errno 111] Connection refused\"))\n" >&2
    exit 1 ;;
  invalid)
    printf 'ERROR: (gcloud.iam.roles.describe) INVALID_ARGUMENT: The role name must be in the form "roles/{role}", "organizations/{organization_id}/roles/{role}", or "projects/{project_id}/roles/{role}".\n' >&2
    exit 1 ;;
  compute-notfound)
    printf "ERROR: (gcloud.compute.networks.describe) Could not fetch resource:\n - The resource 'projects/sol-qualification/global/networks/test-cluster' was not found\n" >&2
    exit 1 ;;
  *)
    printf 'ERROR: (gcloud.iam.service-accounts.describe) NOT_FOUND: Unknown service account. This command is authenticated as lbendtlynielsen@gmail.com which is the active account specified by the [core/account] property\n' >&2
    exit 1 ;;
esac
STUB

cat >"$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$ARGV_LOG"
case "$*" in
  *"logs job/cert-manager-startupapicheck"*)
    case "${STUB_KUBE_SIGNATURE:-none}" in
      x509)      printf 'error: x509: certificate signed by unknown authority\n' ;;
      discovery) printf 'error: no matches for kind "Certificate" in version "cert-manager.io/v1"\n' ;;
      dial)      printf 'error: context deadline exceeded: dial tcp 10.0.0.1:10250: i/o timeout\n' ;;
      *)         : ;;
    esac
    ;;
  *"get job cert-manager-startupapicheck -o json"*)
    printf '{"status":{"succeeded":%s}}\n' "${STUB_JOB_SUCCEEDED:-0}" ;;
esac
exit 0
STUB

cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '{"Answer":[{"data":"ns-cloud-c1.googledomains.com."},{"data":"ns-cloud-c2.googledomains.com."},{"data":"ns-cloud-c3.googledomains.com."},{"data":"ns-cloud-c4.googledomains.com."}]}'
STUB

cat >"$TMP/bin/dig" <<'STUB'
#!/usr/bin/env bash
printf 'qual-gcp.sol-fab.dev.\t3600\tIN\tNS\tns-cloud-c1.googledomains.com.\n'
STUB

cat >"$TMP/bin/gzip" <<'STUB'
#!/usr/bin/env bash
cat
STUB

chmod +x "$TMP"/bin/*

# A fake Sol data directory: copying this out is what proves the bundle does not depend on
# Sol's own 20-run pruning window. It also makes the suite unable to touch the operator's real
# ~/.local/share/sol (INFRA-075's isolation lesson).
SOL_DATA="$TMP/data/sol"
mkdir -p "$SOL_DATA/runs/cloud-apply-20260925T000000Z-1234"
printf 'lifecycle phase: CloudBootstrap\n' >"$SOL_DATA/runs/cloud-apply-20260925T000000Z-1234/phase.log"
printf 'root=platform/cloud/gcp/cluster\n' >"$SOL_DATA/runs/cloud-apply-20260925T000000Z-1234/meta"
printf 'exited 0\n' >"$SOL_DATA/runs/cloud-apply-20260925T000000Z-1234/exit"

# ── the runner ───────────────────────────────────────────────────────────────
run_case() { # run_case <name> <subcommand> [VAR=VALUE ...]
  local name="$1" sub="$2"
  shift 2
  export ARGV_LOG="$TMP/$name.argv"
  export LOG_DIR="$TMP/$name.logs"
  # Scratch workspace: the harness writes the target file into it, so the repository is never
  # touched and "nothing was left behind" is an assertion about scratch, not a hope.
  export WORKSPACE="$SCRATCH_WS"
  export XDG_DATA_HOME="$TMP/data"
  # The identity the harness will ask about: CLUSTER at the harness's default project.
  export STUB_PROVISIONER_SA="test-cluster-provisioner@sol-qualification.iam.gserviceaccount.com"
  : >"$ARGV_LOG"
  rm -f "$TARGET_FILE"
  # The `verify` invariant needs a target file to exist: with one present, the old code
  # would actually have reached `sol cloud destroy`.
  if [ "${PRESEED_TARGET:-0}" = "1" ]; then
    printf '# Written by internal/qualification/gcp/live-qual.sh (test preseed)\nqual:\n  targets:\n    gcp/us-central1:\n      cluster_name: test-cluster\n      base_domain: qual-gcp.sol-fab.dev\n' >"$TARGET_FILE"
  fi
  rm -rf "$LOG_DIR"
  env ALLOW_CANONICAL=1 SOL="$TMP/bin/sol" CLUSTER=test-cluster \
    IMPERSONATOR=user:test@example.com LE_EMAIL=test@example.com \
    PATH="$TMP/bin:$PATH" "$@" \
    "$HARNESS" "$sub" >"$TMP/$name.out" 2>&1
  echo "$? " >"$TMP/$name.rc"
  sed -i 's/ //' "$TMP/$name.rc"
}

# ── 1. a successful cloud run keeps the target; teardown is a separate, deliberate act ──
printf '\nscenario: cloud succeeds\n'
run_case cloud-ok cloud
is "exit 0" "$(cat "$TMP/cloud-ok.rc")" "0"
lacks "no destroy on the success path (the delegation boundary keeps the substrate)" "cloud destroy" "$TMP/cloud-ok.argv"
lacks "the cloud phase never runs an application deploy" "sol deploy" "$TMP/cloud-ok.argv"
has "the target is written for the run" "cluster_name" "$TARGET_FILE"
# H1: the generated target must not ask for an issuer Sol refuses to install on GCP.
lacks "the generated target declares no cluster_issuer (H1)" "cluster_issuer:" "$TARGET_FILE"
present "$TMP/cloud-ok.logs/state/cloud.tfstate" "the cloud state snapshot is in the bundle (H3)"
present "$TMP/cloud-ok.logs/state/platform.tfstate" "the platform state snapshot is in the bundle (H3)"
if [ -s "$TMP/cloud-ok.logs/sol-runs/cloud-apply-20260925T000000Z-1234/phase.log" ]; then
  ok "Sol's own run artifacts are copied into the bundle (H4)"
else
  no "Sol's own run artifacts are copied into the bundle (H4)" "copied" "missing"
fi
present "$TMP/cloud-ok.logs/inventory-pre.tsv" "a pre-teardown provider inventory is captured (H6)"
present "$TMP/cloud-ok.logs/ready-phases.txt" "the Ready-path phase lines are captured"
has "the bundle manifest names the state snapshot" "terraform state (cloud)" "$TMP/cloud-ok.logs/evidence-manifest.txt"

# ── 2. teardown: exactly once, correct variables, target removed only after verification ──
printf '\nscenario: destroy\n'
run_case destroy-ok destroy
is "exit 0" "$(cat "$TMP/destroy-ok.rc")" "0"
is "teardown is invoked" "$([ "$(grep -c 'cloud destroy' "$TMP/destroy-ok.argv")" -ge 1 ] && echo yes)" "yes"
is "teardown is invoked exactly once" "$(grep -c 'cloud destroy' "$TMP/destroy-ok.argv")" "1"
has "destroy carries the cluster" "--var=cluster_name=test-cluster" "$TMP/destroy-ok.argv"
has "destroy carries the base domain" "--var=base_domain=" "$TMP/destroy-ok.argv"
has "destroy carries the impersonator" "provisioner_impersonators" "$TMP/destroy-ok.argv"
# The DEC-043 assertion: the durable zone is never handed to the disposable destroy.
lacks "the durable zone is not passed as disposable intent" "--var=create_dns_zone=true" "$TMP/destroy-ok.argv"
has "the durable zone is explicitly excluded" "--var=create_dns_zone=false" "$TMP/destroy-ok.argv"
# The bundle must be complete before the teardown starts, and the post-teardown inventory must
# land in it too.
present "$TMP/destroy-ok.logs/inventory-pre.tsv" "the pre-teardown inventory precedes teardown"
present "$TMP/destroy-ok.logs/inventory-post.tsv" "the post-teardown inventory is captured"
present "$TMP/destroy-ok.logs/state/cloud.tfstate" "the state snapshot is frozen before teardown (H3)"
if [ -f "$TARGET_FILE" ]; then no "the target is removed after verified teardown" "removed" "still present"; else ok "the target is removed after verified teardown"; fi

# ── 3. verification failure retains the target and exits non-zero ────────────
printf '\nscenario: verification finds a leftover\n'
run_case destroy-leftover destroy STUB_TARGET_PRESENT=1
if [ "$(cat "$TMP/destroy-leftover.rc")" = "0" ]; then no "non-zero exit when resources remain" "non-zero" "0"; else ok "non-zero exit when resources remain"; fi
if [ -f "$TARGET_FILE" ]; then ok "the target is retained when teardown is unverified"; else no "the target is retained when teardown is unverified" "present" "removed"; fi
has "the leftover names a class the contract requires (artifact registry)" "artifact-registry still exists" "$TMP/destroy-leftover.out"

# ── 4. H2: a failed apply captures the discriminator BEFORE the teardown ─────
printf '\nscenario: apply fails at the platform boundary\n'
run_case cloud-fail cloud STUB_APPLY_RC=1 STUB_CLUSTER_EXISTS=1 STUB_KUBE_SIGNATURE=dial
has "a failed apply still tears down" "cloud destroy" "$TMP/cloud-fail.argv"
lacks "the harness never runs an application deploy to diagnose the platform" "sol deploy" "$TMP/cloud-fail.argv"
if [ "$(cat "$TMP/cloud-fail.rc")" = "0" ]; then no "a failed apply exits non-zero" "non-zero" "0"; else ok "a failed apply exits non-zero"; fi
if grep -qF 'cloud apply failed -- capturing the discriminator before any teardown' "$TMP/cloud-fail.out"; then
  ok "the failure path announces the discriminator capture"
else
  no "the failure path announces the discriminator capture" "announced" "silent"
fi
# FND-0010 follow-up: the discriminator must be able to answer "why was the CA bundle never
# injected?" -- the CA the webhook pod writes, the injector's view, and the cert-manager API
# objects. Asserted here so a future edit cannot quietly drop them again.
# Existence, not content: the stub emits nothing for these, and `kube_capture` writes the
# file either way (`|| true`) -- what matters is that the capture happens at all.
for member in fnd0010-ca-secret fnd0010-tls-secret fnd0010-cainjector-logs fnd0010-controller-logs fnd0010-webhook-logs fnd0010-certificates; do
  if [ -f "$TMP/cloud-fail.logs/$member.log" ]; then
    ok "the discriminator captures $member (FND-0010 follow-up)"
  else
    no "the discriminator captures $member (FND-0010 follow-up)" "a file" "missing"
  fi
done
has "the CA secret capture asks for existence, not key material" "keys=" "$TMP/cloud-fail.argv"
probe_line="$(grep -n -m1 'kubectl -n cert-manager logs' "$TMP/cloud-fail.argv" | cut -d: -f1)"
teardown_line="$(grep -n -m1 'cloud destroy' "$TMP/cloud-fail.argv" | cut -d: -f1)"
if [ -n "$probe_line" ] && [ -n "$teardown_line" ] && [ "$probe_line" -lt "$teardown_line" ]; then
  ok "the discriminator probes run BEFORE the teardown (H2, by argv order)"
else
  no "the discriminator probes run BEFORE the teardown (H2, by argv order)" \
    "probe line < teardown line" "probe=${probe_line:-none} teardown=${teardown_line:-none}"
fi
if [ -s "$TMP/cloud-fail.logs/fnd0010-classification.txt" ]; then
  ok "the discriminator classification is in the bundle"
else
  no "the discriminator classification is in the bundle" "present" "missing"
fi
present "$TMP/cloud-fail.logs/inventory-pre.tsv" "the pre-teardown inventory is captured on the failure path (H6)"
present "$TMP/cloud-fail.logs/state/cloud.tfstate" "the state snapshot is captured on the failure path (H3)"
if [ -s "$TMP/cloud-fail.logs/sol-runs/cloud-apply-20260925T000000Z-1234/phase.log" ]; then
  ok "Sol's run artifacts are captured on the failure path (H4)"
else
  no "Sol's run artifacts are captured on the failure path (H4)" "copied" "missing"
fi

# ── 5. the classification is evidence-driven, not a default ──────────────────
# Mutation direction: a classifier that always answers WEBHOOK_REACHABILITY (or always
# UNKNOWN) fails at least one of these three.
printf '\nscenario: classification follows the captured evidence\n'
run_case class-x509 cloud STUB_APPLY_RC=1 STUB_CLUSTER_EXISTS=1 STUB_KUBE_SIGNATURE=x509
has "an x509 signature classifies as TLS_CA_OR_CERTIFICATE (not reachability)" \
  "classification: TLS_CA_OR_CERTIFICATE" "$TMP/class-x509.logs/fnd0010-classification.txt"
run_case class-discovery cloud STUB_APPLY_RC=1 STUB_CLUSTER_EXISTS=1 STUB_KUBE_SIGNATURE=discovery
has "a discovery signature classifies as CRD_OR_API_DISCOVERY" \
  "classification: CRD_OR_API_DISCOVERY" "$TMP/class-discovery.logs/fnd0010-classification.txt"
run_case class-dial cloud STUB_APPLY_RC=1 STUB_CLUSTER_EXISTS=1 STUB_KUBE_SIGNATURE=dial
has "a dial-timeout signature classifies as WEBHOOK_REACHABILITY" \
  "classification: WEBHOOK_REACHABILITY" "$TMP/class-dial.logs/fnd0010-classification.txt"
run_case class-empty cloud STUB_APPLY_RC=1 STUB_CLUSTER_EXISTS=1
has "no usable evidence classifies as UNKNOWN (never reachability by default)" \
  "classification: UNKNOWN" "$TMP/class-empty.logs/fnd0010-classification.txt"

# ── 6. UNKNOWN is not absence: both shapes pinned, separately ────────────────
# Mandatory evidence for the tri-state fix. Only explicit provider not-found evidence
# establishes absence; pinning one unreadable shape and not the other invites the
# implementation to drift into an allowlist of errors that get called absence.
# The provider's own explicit not-found forms are ABSENT -- both the underscore form (the one
# this suite missed) and the compute "was not found" phrasing.
printf '\nscenario: the provider says NOT_FOUND\n'
run_case notfound-underscore destroy STUB_PROBE_MODE=notfound
is "the provider's own NOT_FOUND (underscore) reads as ABSENT" "$(cat "$TMP/notfound-underscore.rc")" "0"
has "and names the class absent" "gke-cluster absent" "$TMP/notfound-underscore.out"
run_case notfound-compute destroy STUB_PROBE_MODE=compute-notfound
is "'was not found' reads as ABSENT" "$(cat "$TMP/notfound-compute.rc")" "0"

for mode in permission transport invalid; do
  printf '\nscenario: probe failed without saying not-found (%s)\n' "$mode"
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
  # The new classes must be tri-state too: a permission failure on the artifact registry is
  # UNKNOWN, not "the registry is gone".
  if grep -q 'artifact-registry: UNKNOWN' "$TMP/probe-$mode.out"; then
    ok "a newly-covered class is UNKNOWN when it cannot be read ($mode)"
  else
    no "a newly-covered class is UNKNOWN when it cannot be read ($mode)" "artifact-registry: UNKNOWN" "$(grep -m1 'artifact-registry' "$TMP/probe-$mode.out" || echo absent)"
  fi
  if [ -f "$TARGET_FILE" ]; then
    ok "the target is retained ($mode)"
  else
    no "the target is retained ($mode)" "present" "removed"
  fi
done

# ── 7. one authoritative input for create_dns_zone, across every invocation ──
printf '\nscenario: no contradictory configuration is ever rendered\n'
if cat "$TMP"/*.argv | grep -qE 'create_dns_zone=true'; then
  no "no invocation asks for the durable zone to be created" "no create_dns_zone=true" "rendered somewhere"
else
  ok "no invocation asks for the durable zone to be created"
fi

# ── 8. a destructive durable reconcile stops the run before anything is created ──
printf '\nscenario: the durable root would be replaced\n'
run_case durable-refusal cloud STUB_PLAN_DESTROYS=1
if [ "$(cat "$TMP/durable-refusal.rc")" = "0" ]; then
  no "a plan that would replace a durable prerequisite refuses" "non-zero" "0"
else
  ok "a plan that would replace a durable prerequisite refuses"
fi
has "the refusal names the durable risk" "REFUSED" "$TMP/durable-refusal.out"
lacks "no cloud apply runs after a refused durable reconcile" "cloud apply" "$TMP/durable-refusal.argv"

# ── 9. the platform phase is refused, because `sol cloud apply` is the install ──
printf '\nscenario: platform subcommand\n'
run_case platform-refused platform
is "exit 2" "$(cat "$TMP/platform-refused.rc")" "2"
has "the refusal points at the invocation that installs the platform" "sol cloud apply" "$TMP/platform-refused.out"
lacks "the refused phase runs nothing" "cloud apply" "$TMP/platform-refused.argv"

# ── 10. process discipline, pinned as source properties ─────────────────────
printf '\nscenario: process discipline\n'
# Code only: the header is *supposed* to name these practices (it explains why they are
# forbidden), so the check strips comments before looking for them.
grep -vE '^[[:space:]]*#' "$HARNESS" >"$TMP/harness-code.sh"
for forbidden in 'pkill' 'killall' 'force-unlock' 'kill -9' 'kill -KILL' 'kill -s KILL'; do
  if grep -qF -- "$forbidden" "$TMP/harness-code.sh"; then
    no "the harness contains no '$forbidden' in code" "absent" "present"
  else
    ok "the harness contains no '$forbidden' in code"
  fi
done
if grep -qF 'kill -TERM -"$pgid"' "$HARNESS"; then
  ok "stopping acts on the recorded process group (identity, not pattern)"
else
  no "stopping acts on the recorded process group (identity, not pattern)" 'kill -TERM -"$pgid"' "missing"
fi
if grep -qF 'run.pgid' "$HARNESS"; then
  ok "the run records its own process-group identity"
else
  no "the run records its own process-group identity" "run.pgid" "missing"
fi

# ── 11. the quota verdict follows the numbers, in both directions ────────────
# The old check had no positive control: an all-zero read and a busy account were never
# distinguished by a test, so a pattern that always says "busy" (or never) passed.
printf '\nscenario: quota verdict\n'
has "an all-zero usage read is ABSENT, not a violation" "quota: ABSENT" "$TMP/destroy-ok.out"
run_case quota-busy destroy STUB_QUOTA_BUSY=1
has "non-zero usage reads as PRESENT" "quota: PRESENT" "$TMP/quota-busy.out"
if [ "$(cat "$TMP/quota-busy.rc")" = "0" ]; then
  no "non-zero usage fails the verification" "non-zero" "0"
else
  ok "non-zero usage fails the verification"
fi
run_case quota-garbage destroy STUB_QUOTA_GARBAGE=1
has "an unparsable usage read is UNKNOWN" "quota: UNKNOWN" "$TMP/quota-garbage.out"
if [ "$(cat "$TMP/quota-garbage.rc")" = "0" ]; then
  no "an unparsable usage read fails the verification" "non-zero" "0"
else
  ok "an unparsable usage read fails the verification"
fi

# ── 12. the bundle check has teeth: a member that could not be read fails the run ──
# The state read failing is the interesting shape: the file exists but is empty, which is
# exactly how an unreadable state would look if nobody checked.
printf '\nscenario: an unreadable bundle member\n'
lacks "a complete bundle is not reported as incomplete" "evidence bundle is INCOMPLETE" "$TMP/cloud-fail.out"
run_case bundle-unreadable cloud STUB_APPLY_RC=1 STUB_CLUSTER_EXISTS=1 STUB_STATE_UNREADABLE=1
has "an empty state snapshot is named as a missing bundle member" \
  "bundle member missing or empty: state/cloud.tfstate" "$TMP/bundle-unreadable.out"
has "an incomplete bundle is reported as non-conformant" \
  "evidence bundle is INCOMPLETE" "$TMP/bundle-unreadable.out"
if [ "$(cat "$TMP/bundle-unreadable.rc")" = "0" ]; then
  no "an incomplete bundle fails the run" "non-zero" "0"
else
  ok "an incomplete bundle fails the run"
fi

# ── 13. a warning on stderr is not an answer ─────────────────────────────────
# Found by running the probe against the live project: an empty filtered list writes a warning
# to stderr, and a probe that merges the streams reads it as PRESENT. Absence stays absence.
printf '\nscenario: a filtered list that warns\n'
run_case filter-warning destroy STUB_FILTER_WARNING=1
has "an empty filtered list is ABSENT even when gcloud warns on stderr" "quota: ABSENT" "$TMP/filter-warning.out"
if grep -q 'address-regional: PRESENT' "$TMP/filter-warning.out"; then
  no "the warning is not read as a resource" "address-regional: ABSENT" "PRESENT"
else
  ok "the warning is not read as a resource"
fi
is "the warned verification still passes" "$(cat "$TMP/filter-warning.rc")" "0"

# ── 14. `verify` is observational, on both paths ─────────────────────────────
# The invariant is about behaviour, not about where a flag is set: with a target file present,
# a failing verification must still invoke no destroy. (Before the fix this case reached
# `sol cloud destroy` -- the stop recorded in
# internal/qualification/records/2026-09-25-gcp-attempt8-phase0-stop.md.)
printf '\nscenario: verify is read-only even when it fails\n'
PRESEED_TARGET=1 run_case verify-fail verify STUB_TARGET_PRESENT=1
if [ "$(cat "$TMP/verify-fail.rc")" = "0" ]; then
  no "a failing verification exits non-zero" "non-zero" "0"
else
  ok "a failing verification exits non-zero"
fi
lacks "a failing verification invokes no teardown, even with a target file present" "cloud destroy" "$TMP/verify-fail.argv"
has "it still reports what it saw" "resources remain" "$TMP/verify-fail.out"
PRESEED_TARGET=1 run_case verify-clean verify
is "a clean verification exits 0" "$(cat "$TMP/verify-clean.rc")" "0"
lacks "a clean verification invokes no teardown" "cloud destroy" "$TMP/verify-clean.argv"
if grep -q 'NOT_FOUND: Unknown service account' "$HERE/test-live-qual.sh"; then
  ok "the not-found fixture is the provider's captured wording (underscore form), not a paraphrase"
else
  no "the not-found fixture is the provider's captured wording (underscore form), not a paraphrase" \
    "NOT_FOUND: Unknown service account" "absent"
fi

# ── 15. the attempt's target key is its own ──────────────────────────────────
# The key names the Terraform state objects, so a shared key means a shared state:
# Attempt 8's failed install left platform state behind at its key, and an attempt
# that reuses the key inherits it instead of producing its own specimen.
printf '\nscenario: the target key is overridable\n'
TARGET=qual9/gcp/us-central1 run_case target-override destroy
has "the override reaches sol" "cloud destroy qual9/gcp/us-central1" "$TMP/target-override.argv"
has "and names the state objects it will read" "sol/qual9/gcp/us-central1/cloud.tfstate" "$TMP/target-override.argv"
if grep -q 'sol/qual/gcp/us-central1/' "$TMP/target-override.argv"; then
  no "the default key is not silently used as well" "no sol/qual/ path" "found one"
else
  ok "the default key is not silently used as well"
fi

# ── 16. postconditions a describe cannot answer (INFRA-080) ───────────────────
# The shape Attempt 9's bundle recorded, replayed offline: the disposable infrastructure is
# gone, the provisioner identity is provider-deleted (so its describe answers
# PERMISSION_DENIED, which establishes nothing), the impersonation grant is unusable because
# the identity it was attached to is not active, the custom role is provider-deleted into
# GCP's undelete window, and the durable prerequisites are present. Teardown must VERIFY —
# and it must say, per class, which evidence established what.
printf '\nscenario: Attempt-9-shaped teardown verifies\n'
run_case attempt9-verified destroy
is "a clean teardown with a provider-deleted identity and role verifies" "$(cat "$TMP/attempt9-verified.rc")" "0"
has "the fixture asked about the harness's own provisioner identity" "$STUB_PROVISIONER_SA" "$TMP/attempt9-verified.argv"
has "the identity class is ABSENT for the right reason" "service-account-provisioner: ABSENT" "$TMP/attempt9-verified.out"
has "and names the authoritative observable" "not in the active list" "$TMP/attempt9-verified.out"
has "the binding class is ABSENT for the right reason" "impersonator-binding: ABSENT" "$TMP/attempt9-verified.out"
has "and names the implication, not a relabelled denial" "cannot be impersonated" "$TMP/attempt9-verified.out"
has "the role class is ABSENT for the right reason" "custom-role: ABSENT" "$TMP/attempt9-verified.out"
has "and reports the provider's own deletion marker" "provider-deleted" "$TMP/attempt9-verified.out"
has "the raw deletion marker is preserved in the bundle" "True" "$TMP/attempt9-verified.logs/inventory-custom-role.log"
has "the raw describe answer for the deleted identity is preserved" "PERMISSION_DENIED" "$TMP/attempt9-verified.logs/inventory-service-account-provisioner.describe.log"
if grep -q 'could NOT determine absence' "$TMP/attempt9-verified.out"; then
  no "nothing is left UNKNOWN in this shape" "no UNKNOWN" "$(grep -m1 'could NOT determine' "$TMP/attempt9-verified.out")"
else
  ok "nothing is left UNKNOWN in this shape"
fi

# The mutations: each one makes a security-sensitive fact true, and verification must not pass.
printf '\nscenario: the identity is still active\n'
run_case mutation-sa-active destroy STUB_SA_ACTIVE_PROVISIONER=1 STUB_SA_POLICY=empty
if [ "$(cat "$TMP/mutation-sa-active.rc")" = "0" ]; then
  no "an active provisioner identity fails the verification" "non-zero" "0"
else
  ok "an active provisioner identity fails the verification"
fi
has "and is reported PRESENT" "service-account-provisioner: PRESENT" "$TMP/mutation-sa-active.out"

printf '\nscenario: the impersonation grant is still there\n'
run_case mutation-binding-present destroy STUB_SA_ACTIVE_PROVISIONER=1 STUB_SA_POLICY=binding
if [ "$(cat "$TMP/mutation-binding-present.rc")" = "0" ]; then
  no "a surviving impersonator binding fails the verification" "non-zero" "0"
else
  ok "a surviving impersonator binding fails the verification"
fi
has "and is reported PRESENT" "impersonator-binding: PRESENT" "$TMP/mutation-binding-present.out"

printf '\nscenario: the role is still active\n'
run_case mutation-role-active destroy STUB_ROLE_STATE=active
if [ "$(cat "$TMP/mutation-role-active.rc")" = "0" ]; then
  no "an active custom role fails the verification" "non-zero" "0"
else
  ok "an active custom role fails the verification"
fi
has "and is reported PRESENT" "custom-role: PRESENT" "$TMP/mutation-role-active.out"

# Ambiguous evidence stays ambiguous, per class: an active identity whose policy read is
# denied must not become "the binding is gone".
printf '\nscenario: the policy read is denied while the identity is active\n'
run_case mutation-policy-denied destroy STUB_SA_ACTIVE_PROVISIONER=1
has "the binding class is UNKNOWN when its read is ambiguous" "impersonator-binding: UNKNOWN" "$TMP/mutation-policy-denied.out"
if [ "$(cat "$TMP/mutation-policy-denied.rc")" = "0" ]; then
  no "ambiguous policy evidence does not verify" "non-zero" "0"
else
  ok "ambiguous policy evidence does not verify"
fi

printf '\nscenario: the authoritative collection itself fails\n'
run_case mutation-list-fails destroy STUB_SA_LIST_FAIL=1
has "a failed authoritative list is UNKNOWN, never absent" "service-account-provisioner: UNKNOWN" "$TMP/mutation-list-fails.out"
has "and the binding does not guess either" "impersonator-binding: UNKNOWN" "$TMP/mutation-list-fails.out"
if [ "$(cat "$TMP/mutation-list-fails.rc")" = "0" ]; then
  no "an unreadable authority collection does not verify" "non-zero" "0"
else
  ok "an unreadable authority collection does not verify"
fi

printf '\nscenario: the role is genuinely not found / unreadable\n'
run_case role-notfound destroy STUB_ROLE_STATE=notfound
is "a not-found role verifies" "$(cat "$TMP/role-notfound.rc")" "0"
run_case role-unreadable destroy STUB_ROLE_STATE=error
has "an unreadable role is UNKNOWN" "custom-role: UNKNOWN" "$TMP/role-unreadable.out"

# ── 17. the harness's own argument list (INFRA-080 C) ─────────────────────────
# The generated target is the single source for the impersonator: Sol routes it from the
# target's `gcp` block. The harness must not pass a second copy behind a comment that ends
# its own printf -- which is what printed `command not found` while dropping the argument.
printf '\nscenario: the harness passes no dead argument\n'
run_case cloud-vars cloud
lacks "no command-not-found diagnostic" "command not found" "$TMP/cloud-vars.out"
has "the generated target carries the impersonator" "provisioner_impersonator: user:test@example.com" "$TARGET_FILE"
lacks "and the cloud path passes no second copy of it" "-var=provisioner_impersonators" "$TMP/cloud-vars.argv"

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
