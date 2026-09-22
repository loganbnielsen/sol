#!/usr/bin/env bash
# GCP qualification attempt harness (HARDEN-004).
#
# The AWS workstream has internal/qualification/aws/live-smoke.sh; the GCP attempts
# had no equivalent, so the recipe lived in a session rather than in the repository
# and Attempt 5 was not reproducible from the tree. This is the GCP twin, and it is
# built around three rules that the AWS harness established:
#
#   1. **Teardown is unconditional.** A trap runs `destroy` on every exit path, and
#      `destroy` verifies absence through the provider's API — not through
#      Terraform's exit status, which only says what Terraform believes.
#   2. **The evidence is captured before anything is changed.** The attempt's
#      product is an evidence bundle in $LOG_DIR, not a live cluster.
#   3. **No personal defaults.** The caller must name the identity and the cluster,
#      so a clean clone cannot point at someone else's account or an old cluster.
#
# What it deliberately does NOT do: speculate about, or remediate, the
# `startupapicheck` failure the previous attempts stopped at (FND-0010). It runs the
# platform install, captures what the cluster actually says, and stops. Classifying
# that evidence is a separate, deliberate step — a harness that "tries the likely
# firewall fix" destroys the experiment it was written to perform.
#
# Two prerequisites this harness does NOT yet satisfy, both found by running it (a
# PLAN_ONLY cloud run fails closed on the first, which is the point of having it):
#
#   1. **A state bucket, and no GCP path that creates one.** `sol cloud` refuses to
#      initialize Terraform until the target declares `state_bucket`, because a
#      Terraform root cannot create its own backend. The AWS side provisions the pair
#      from `cli/platform/infra/bootstrap/`, which is AWS-only (`provider "aws"`,
#      `aws_s3_bucket`, `aws_dynamodb_table`) — so on GCP the bucket is either created
#      once out of band and recorded in the untracked target, or a GCP bootstrap root
#      is authored. GCS needs no lock table.
#   2. **The target's profile fields.** A qualification target is much richer than a
#      dev target: `docs/qualification/run8-aws-target.example.yml` carries `profile`,
#      `kube_context`, `registry`, the four role identities, `cluster_endpoint_cidr`,
#      the alert quartet (a guarantee the profile requires, not an option),
#      `node_failure_headroom_nodes` and `destroy_retention: none`. The GCP variants of
#      those must be derived from the config schema and the GCP preflight rather than
#      invented here, which is why this harness currently writes only the fields it can
#      justify and stops at the first missing prerequisite instead of guessing.
#
# Usage:
#   internal/qualification/gcp/live-qual.sh cloud      # bootstrap + zone + NS capture, then STOP
#   internal/qualification/gcp/live-qual.sh platform   # platform install + FND-0010 probes, then teardown
#   internal/qualification/gcp/live-qual.sh destroy    # teardown + independent absence verification
#   internal/qualification/gcp/live-qual.sh verify     # absence verification only (no mutation)
#
# Required environment (no defaults, deliberately):
#   CLUSTER       unique cluster name for this run, e.g. sol-qual-gcp-5
#   IMPERSONATOR  the calling identity, e.g. user:you@example.com
#   LE_EMAIL      ACME contact address for the ClusterIssuer
#
# Optional:
#   PROJECT       default sol-qualification
#   BASE_DOMAIN   default qual-gcp.sol-fab.dev (DEC-042)
#   PHASE_TIMEOUT default 1200 seconds per phase
#   DELEGATION_WAIT_MINUTES  default 25 — how long `cloud` waits for the delegation
#                            to become visible before giving up (bounded on purpose:
#                            billable infrastructure exists during this wait)
#   LOG_DIR       default /tmp/sol-gcp-qual-<timestamp>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# The CLI under test. Defaults to this checkout's build so an attempt is identifiable
# by commit; overridable for a plan-only validation.
SOL="${SOL:-$ROOT/_build/default/cli/sol/bin/main.exe}"
WORKSPACE="$ROOT/examples/pluto"
TFVARS="$ROOT/internal/qualification/gcp/qual-gcp.tfvars"

# The qualification target is generated, not committed: check_no_account_artifacts.sh
# refuses a tracked `sol/qual/` path, which is the repository's way of saying a
# provisioned-target definition is scratch. It is removed on exit.
TARGET="qual/gcp/us-central1"
TARGET_FILE="$WORKSPACE/sol/$TARGET.yml"

PROJECT="${PROJECT:-sol-qualification}"
REGION="${REGION:-us-central1}"
BASE_DOMAIN="${BASE_DOMAIN:-qual-gcp.sol-fab.dev}"
PHASE_TIMEOUT="${PHASE_TIMEOUT:-1200}"
DELEGATION_WAIT_MINUTES="${DELEGATION_WAIT_MINUTES:-25}"
LOG_DIR="${LOG_DIR:-/tmp/sol-gcp-qual-$(date +%Y%m%d-%H%M%S)}"

# Requirements are per subcommand, and the messages deliberately avoid an apostrophe:
# inside a ${var:?word} expansion bash treats a single quote as a quote character, so
# "Let's" there silently opens a string that runs to the next apostrophe in the file.
case "${1:-}" in
  cloud | platform)
    CLUSTER="${CLUSTER:?Set CLUSTER to a unique cluster name for this run, e.g. sol-qual-gcp-5}"
    IMPERSONATOR="${IMPERSONATOR:?Set IMPERSONATOR to the calling identity, e.g. user:you@example.com}"
    LE_EMAIL="${LE_EMAIL:?Set LE_EMAIL to an ACME contact address}"
    ;;
  destroy | verify | "")
    # `verify` and `destroy` must stay usable without the mutating phases' variables:
    # they are what a caller reaches for when a run has already gone wrong.
    if [ -n "${1:-}" ]; then
      CLUSTER="${CLUSTER:?Set CLUSTER to the cluster name to check}"
    fi
    ;;
esac

# The zone's name in Cloud DNS is derived from base_domain by the cloud root.
ZONE_NAME="$(printf '%s' "$BASE_DOMAIN" | tr '.' '-')"

say() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }

# ── environment identity, asserted rather than remembered ────────────────────
# Three times in one session the environment was not what the operator believed: a
# file written into a directory that was never a worktree, a ticket removed from the
# canonical checkout, and a guard run from the wrong tree. Prose reminders failed, so
# the harness asserts it, before it writes anything or touches the provider.
assert_environment() {
  local top
  top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "✗ $ROOT is not inside a git work tree — refusing to run." >&2
    echo "  A qualification run is identified by the revision it ran from, so it needs one." >&2
    exit 2
  }
  if [ "$(cd "$top" && pwd -P)" != "$(cd "$ROOT" && pwd -P)" ]; then
    echo "✗ refusing: the harness lives in $ROOT but its work tree's top level is $top." >&2
    exit 2
  fi
  # This harness writes the untracked target into the example workspace, so it must not
  # run in the canonical checkout, which belongs to the human operator (REFAC-090).
  local canonical
  canonical="$(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
  if [ "$(cd "$canonical" && pwd -P)" = "$(cd "$ROOT" && pwd -P)" ] && [ "${ALLOW_CANONICAL:-0}" != "1" ]; then
    echo "✗ refusing to run in the canonical checkout ($ROOT)." >&2
    echo "  Run from a worktree, or set ALLOW_CANONICAL=1 if you own this checkout." >&2
    exit 2
  fi
  say "environment: work tree $top, revision $(git -C "$ROOT" rev-parse --short HEAD)"
}
assert_environment

# The phases that mutate need the CLI; `verify` is provider-side reads only and must
# stay usable from an unbuilt tree, which is exactly the situation it is reached for in.
if [ "${1:-}" != "verify" ]; then
  [ -x "$SOL" ] || {
    echo "✗ CLI not built at $SOL" >&2
    echo "  Build it in this checkout so the attempt is identifiable by commit:" >&2
    echo "    eval \$(opam env) && dune build cli/sol/bin/main.exe" >&2
    exit 2
  }
fi

mkdir -p "$LOG_DIR"
# The per-run password is generated, never stored in the repository, and never needed
# again after the attempt (the instance is destroyed).
DB_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"

KEEP=0            # set to 1 only at the deliberate delegation boundary
CLOUD_APPLIED=0   # whether a cloud root may exist and therefore need destroying

# Run one phase, logging it, failing the script if it fails. Used for everything whose
# failure is not itself the evidence we came for.
#
# Every Sol command runs with the workspace as its working directory: a Sol workspace
# is identified by sol.yml, and the target path resolves relative to it. `timeout`
# cannot invoke a shell function, so the cd happens in a subshell here rather than in
# a wrapper the timeout would have to exec.
run() {
  local name="$1"; shift
  say "phase: $name"
  if ! ( cd "$WORKSPACE" && timeout "$PHASE_TIMEOUT" "$@" ) >"$LOG_DIR/$name.log" 2>&1; then
    say "FAILED: $name  (last 40 lines; full log $LOG_DIR/$name.log)"
    tail -n 40 "$LOG_DIR/$name.log" || true
    return 1
  fi
  say "ok: $name"
}

write_target() {
  mkdir -p "$(dirname "$TARGET_FILE")"
  cat >"$TARGET_FILE" <<YAML
target:
  cluster_name: $CLUSTER
  base_domain: $BASE_DOMAIN
  cluster_issuer: letsencrypt-staging
  letsencrypt_email: $LE_EMAIL
  terraform_var_file: ../../../../../internal/qualification/gcp/qual-gcp.tfvars

# The platform layer is what this attempt is about. Application resources and
# services are omitted so the attempt is cheap and the failure it is looking for
# cannot be confused with a workload failure.
resources:
  app_db:
    omit: true
  events:
    omit: true

services:
  charge_svc:
    omit: true
  notify_worker:
    omit: true
YAML
  say "wrote target $TARGET_FILE"
}

cloud_vars() {
  printf '%s\n' \
    "--var-file=$TFVARS" \
    "--var=cluster_name=$CLUSTER" \
    "--var=base_domain=$BASE_DOMAIN" \
    "--var=create_dns_zone=true" \
    "--var=db_password=$DB_PASSWORD" \
    "--var=provisioner_impersonators=[\"$IMPERSONATOR\"]"
}

# ── absence verification: the provider's own answer, not Terraform's ──────────
# The DNS zone is the one thing that must SURVIVE (DEC-042: it is a durable
# prerequisite, and a recreated zone gets new nameservers that silently invalidate
# the delegation). Everything else must be gone, including the service-networking
# peering, which has twice been the abandoned resource in this workstream.
verify_absent() {
  local rc=0
  say "verify: independence from Terraform's exit status — asking the provider"

  probe_gone() { # name, command...
    local name="$1"; shift
    if "$@" >"$LOG_DIR/verify-$name.log" 2>&1; then
      say "  ✗ $name still exists"
      rc=1
    else
      say "  ✓ $name absent"
    fi
  }

  probe_gone gke-cluster gcloud container clusters describe "$CLUSTER" \
    --region "$REGION" --project "$PROJECT"
  probe_gone sql-instance gcloud sql instances describe "$CLUSTER-postgres" \
    --project "$PROJECT"
  probe_gone network gcloud compute networks describe "$CLUSTER-vpc" \
    --project "$PROJECT"

  local n
  for pair in "addresses:$CLUSTER" "disks:$CLUSTER" "forwarding-rules:$CLUSTER"; do
    local what="${pair%%:*}" filt="${pair##*:}"
    n="$(gcloud compute "$what" list --project "$PROJECT" \
      --filter="name~$filt" --format='value(name)' 2>/dev/null | wc -l)"
    if [ "$n" = "0" ]; then say "  ✓ no $what matching $filt"; else say "  ✗ $n $what remain"; rc=1; fi
  done

  # Service-networking peering: abandoned twice in this workstream, so it is checked
  # by name rather than inferred from the network's absence.
  if gcloud compute networks peerings list --project "$PROJECT" \
    --format='value(name)' 2>/dev/null | grep -q 'servicenetworking'; then
    say "  ✗ servicenetworking peering remains"
    rc=1
  else
    say "  ✓ no servicenetworking peering"
  fi

  # The zone must be present. Reported, never treated as a failure: destroying it
  # would break the delegation DEC-042 deliberately made durable.
  if gcloud dns managed-zones describe "$ZONE_NAME" --project "$PROJECT" \
    >"$LOG_DIR/verify-dns-zone.log" 2>&1; then
    say "  ✓ dns zone $ZONE_NAME retained (DEC-042: durable by design)"
  else
    say "  · dns zone $ZONE_NAME absent (nothing delegated yet, or the zone was removed)"
  fi

  # Quota usage is the cheap global cross-check: usage 0 across the board means the
  # project is idle. Ubuntu-style per-resource probes above are the precise answer;
  # this catches anything they do not know how to look for.
  gcloud compute regions describe "$REGION" --project "$PROJECT" \
    --format='csv[no-heading](quotas.metric,quotas.usage)' \
    >"$LOG_DIR/verify-quota.log" 2>&1 || true
  python3 - "$LOG_DIR/verify-quota.log" <<'PY' >"$LOG_DIR/verify-quota-usage.log" 2>&1 || true
import sys
metrics, usage = open(sys.argv[1]).read().strip().split(",")
want = {"CPUS", "IN_USE_ADDRESSES", "SSD_TOTAL_GB", "DISKS_TOTAL_GB", "INSTANCES"}
for m, u in zip(metrics.split(";"), usage.split(";")):
    if m in want:
        print(f"{m}\t{u or '0'}")
PY
  say "  quota usage (CPUS/addresses/disk/instances):"
  sed 's/^/    /' "$LOG_DIR/verify-quota-usage.log" || true
  if grep -qvE '	0(\.0)?$' "$LOG_DIR/verify-quota-usage.log" 2>/dev/null; then
    say "  ✗ some quota usage is non-zero — read $LOG_DIR/verify-quota.log"
    rc=1
  fi

  return "$rc"
}

destroy() {
  say "teardown: sol cloud destroy $TARGET"
  ( cd "$WORKSPACE" && "$SOL" cloud destroy "$TARGET" --apply ) \
    >"$LOG_DIR/destroy.log" 2>&1 || say "  (destroy exited non-zero; the verification below decides)"
  # A destroy that exits 0 is not evidence of cost-cleanliness, and one that exits
  # non-zero may still have removed everything. The provider decides.
  if verify_absent; then
    say "teardown verified: absent"
    TEARDOWN_OK=1
  else
    say "teardown NOT verified: resources remain — see $LOG_DIR/verify-*.log"
    TEARDOWN_OK=0
  fi
}

cleanup() {
  local rc=$?
  rm -f "$TARGET_FILE"
  if [ "$KEEP" = "1" ]; then
    say "not tearing down: ${KEEP_REASON:-the delegation boundary is deliberate, not a leak}"
    say "logs: $LOG_DIR"
    return "$rc"
  fi
  # A plan-only run creates nothing, so a failure there must not reach for the
  # teardown path. Every other failure does: a run of this harness that failed is
  # presumed to have possibly created something, and the verification decides.
  if [ "$CLOUD_APPLIED" = "1" ] || { [ "$rc" != "0" ] && ! plan_only; }; then
    destroy || true
  fi
  say "logs: $LOG_DIR"
  [ "$TEARDOWN_OK" = "1" ] || rc=1
  return "$rc"
}
TEARDOWN_OK=0
trap cleanup EXIT

# ── phases ───────────────────────────────────────────────────────────────────
plan_only() { [ "${PLAN_ONLY:-0}" = "1" ]; }

phase_cloud() {
  write_target
  # shellcheck disable=SC2046
  local vars; mapfile -t vars < <(cloud_vars)

  if plan_only; then
    run cloud-plan "$SOL" cloud plan "$TARGET" "${vars[@]}"
    say "PLAN_ONLY=1: nothing created; target and variables validated"
    return 0
  fi

  CLOUD_APPLIED=1
  run cloud-apply "$SOL" cloud apply "$TARGET" "${vars[@]}" || return 1

  # Capture the delegation hand-off the moment the zone exists. This is the one
  # value the run cannot produce for itself: the parent zone is managed at a
  # registrar with no API, so a human pastes these four records.
  if ! gcloud dns managed-zones describe "$ZONE_NAME" --project "$PROJECT" \
    --format='value(nameServers)' >"$LOG_DIR/nameservers.txt" 2>"$LOG_DIR/nameservers.err"; then
    say "could not read the zone's nameservers — the delegation half cannot proceed"
    return 1
  fi
  say "authoritative nameservers for $BASE_DOMAIN (paste these at Squarespace as NS records named 'qual-gcp'):"
  tr ';' '\n' <"$LOG_DIR/nameservers.txt" | sed 's/^/    /'

  # Wait — bounded — for the delegation to become visible, so the platform stage can
  # follow without a second cold start. This is the intentional pause: billable
  # infrastructure exists, so it is capped and it always reports where it is.
  local deadline=$(( $(date +%s) + DELEGATION_WAIT_MINUTES * 60 ))
  say "waiting up to ${DELEGATION_WAIT_MINUTES}m for the delegation to resolve (Ctrl-C to continue later)"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if dig +short NS "$BASE_DOMAIN" @1.1.1.1 2>/dev/null | grep -q .; then
      say "delegation observed: $(dig +short NS "$BASE_DOMAIN" @1.1.1.1 | tr '\n' ' ')"
      KEEP=1
      return 0
    fi
    sleep 15
  done
  say "delegation not observed within ${DELEGATION_WAIT_MINUTES}m."
  say "This is 'waiting on an external prerequisite', not a Sol failure: finish the NS"
  say "records at Squarespace, then run: CLUSTER=$CLUSTER ... live-qual.sh platform"
  KEEP=1
  return 0
}

phase_platform() {
  write_target
  # The platform install is the phase EXPECTED to fail at cert-manager (FND-0010).
  # Its failure is the evidence, so it is not run through `run` (which would abort
  # before the probes are captured).
  say "phase: platform-install (failure here is expected and is the evidence)"
  ( cd "$WORKSPACE" && timeout "$PHASE_TIMEOUT" "$SOL" deploy "$TARGET" ) \
    >"$LOG_DIR/platform-install.log" 2>&1 || say "platform install exited non-zero (expected)"

  capture_fnd0010
}

# The three probes FND-0010 names, in the order it names them, captured BEFORE any
# remediation is contemplated. The first is the discriminator: the check container's
# own output, which no previous attempt captured, decides between a webhook
# reachability cause (dial timeout / context deadline), a webhook CA cause
# (x509 unknown authority), and a CRD-serving cause.
capture_fnd0010() {
  say "capturing FND-0010 discriminator evidence (no remediation)"
  local kube=(kubectl)
  local ctx
  if ! ctx="$(gcloud container clusters describe "$CLUSTER" --region "$REGION" \
      --project "$PROJECT" --format='value(name)' 2>/dev/null)" || [ -z "$ctx" ]; then
    say "  cluster is not describable — the platform phase cannot have run; nothing to probe"
    return 0
  fi
  gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" \
    --project "$PROJECT" >"$LOG_DIR/kubeconfig.log" 2>&1 || true

  local probe
  probe() {
    local name="$1"; shift
    "$@" >"$LOG_DIR/fnd0010-$name.log" 2>&1 || true
    say "  captured fnd0010-$name.log ($(wc -l <"$LOG_DIR/fnd0010-$name.log") lines)"
  }

  probe startupapicheck-logs "${kube[@]}" -n cert-manager logs \
    job/cert-manager-startupapicheck --all-containers --tail=-1
  probe events "${kube[@]}" -n cert-manager get events --sort-by=.lastTimestamp
  probe job "${kube[@]}" -n cert-manager describe job cert-manager-startupapicheck
  probe webhook-target-port "${kube[@]}" -n cert-manager get svc cert-manager-webhook \
    -o jsonpath='{.spec.ports[*].targetPort}'
  probe pods "${kube[@]}" -n cert-manager get pods -o wide
  probe firewall-rules gcloud compute firewall-rules list --project "$PROJECT" \
    --filter="name~$CLUSTER" --format='table(name,sourceRanges.list(),allowed[].map().firewall_rule().list(),targetTags.list())'
  probe cluster-master-cidr gcloud container clusters describe "$CLUSTER" \
    --region "$REGION" --project "$PROJECT" --format='value(privateClusterConfig.masterIpv4CidrBlock)'

  say "evidence bundle: $LOG_DIR"
  say "classify from fnd0010-startupapicheck-logs.log first; do not remediate before that"
}

phase_destroy() {
  CLOUD_APPLIED=1
  destroy
}

case "${1:-}" in
  cloud)    phase_cloud ;;
  platform) phase_platform ;;
  destroy)  phase_destroy ;;
  verify)
    if verify_absent; then say "verify: absent"; else say "verify: resources remain"; exit 1; fi
    KEEP=1 # verify must not destroy anything
    KEEP_REASON="verify does not mutate; nothing to tear down"
    ;;
  *)
    sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
