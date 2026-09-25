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
#   2. **The target's fields, derived from the contract rather than copied from AWS.**
#      `docs/qualification/run8-aws-target.example.yml` is an *AWS* target: it carries
#      `kube_context`, `registry`, four role ARNs and `cluster_endpoint_cidr`, none of
#      which are GCP-shaped. The symmetry here is capability, not configuration: GCP
#      declares one `provisioner_impersonator` where AWS carries a provisioner role
#      ARN, and carries no lock table because GCS serializes state natively. This
#      harness therefore writes only the fields `config.ml`'s target record actually
#      has and the GCP contract requires, and stops at the first missing prerequisite
#      rather than guessing.
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
# Overridable so a test can point the harness at a scratch workspace: the target file is
# written into it, and a suite that writes into the repository cannot assert that nothing
# was left behind.
WORKSPACE="${WORKSPACE:-$ROOT/examples/pluto}"
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
STATE_BUCKET="${STATE_BUCKET:-sol-qualification-tfstate}"
PROFILE_NAME="${PROFILE_NAME:-production-single-region}"
BOOTSTRAP_ROOT="$ROOT/cli/platform/infra/bootstrap-gcp"

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
ZONE_LABEL="${BASE_DOMAIN%%.*}"   # the registrar's Name field takes the label alone

say() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }

# Nameserver lookup that does not assume outbound port 53. Attempt 5's environment
# blocks plain DNS entirely -- `dig` answered nothing even for the apex, while the
# delegation was in fact live -- so a dig-only wait would have sat for its full
# timeout and then reported "not delegated". DoH travels over HTTPS, which is the same
# path everything else here uses.
dns_ns() {
  local name="$1" out
  out="$(curl -s -H 'accept: application/dns-json' \
      "https://dns.google/resolve?name=$name&type=NS" 2>/dev/null \
    | python3 -c "import sys,json;print('\n'.join(sorted(a.get('data','') for a in json.load(sys.stdin).get('Answer',[]))))" 2>/dev/null)"
  if [ -n "$out" ]; then printf '%s\n' "$out"; else dig +short NS "$name" 2>/dev/null || true; fi
}

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
  # NOT `awk '...exit'`: an early-exiting reader SIGPIPEs git, and with `set -o pipefail`
  # that kills the harness outright -- which it did, silently, once enough worktrees
  # existed for git's output to outlive the reader. It failed in the verification path,
  # where silence is the worst possible symptom. Consume the whole stream, then choose.
  canonical="$(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{ if (!found) { print $2; found = 1 } }')"
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
# A run records its own identity so it can be stopped by pid/pgid rather than by matching
# a command line. Pattern matching is the wrong primitive here: it kills whatever happens
# to contain the pattern, including the shell issuing the kill, and killing a run at the
# wrong moment is how an orphaned `terraform apply` left provider resources outside state.
echo "$$" >"$LOG_DIR/run.pid"
ps -o pgid= -p "$$" 2>/dev/null | tr -d " " >"$LOG_DIR/run.pgid" || true
# The per-run password is generated, never stored in the repository, and never needed
# again after the attempt (the instance is destroyed).
DB_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
# Passed to Terraform through the environment, never through argv: a `-var=` argument
# is echoed into every phase log (and is visible in the process table), which is how
# Attempt 5's generated password ended up written to disk.
export TF_VAR_db_password="$DB_PASSWORD"

KEEP=0            # set to 1 only at the deliberate delegation boundary
CLOUD_APPLIED=0   # whether a cloud root may exist and therefore need destroying
# Teardown has ONE owner (cleanup), and this is how it knows whether it has already run.
# Without it, `destroy` (the command) ran the teardown and then the EXIT trap ran it again,
# byte-identical, on a run that had already verified absent -- two independently active
# owners of cleanup, which is how later changes turn into races and misleading logs.
TEARDOWN_ATTEMPTED=0

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
  profile: $PROFILE_NAME
  cluster_issuer: letsencrypt-staging
  letsencrypt_email: $LE_EMAIL
  terraform_var_file: ../../../../../internal/qualification/gcp/qual-gcp.tfvars

  # The durable state backend: provisioned once by ensure_state_bucket() and merely
  # CONSUMED here. state_lock_table is deliberately absent -- GCS serializes state
  # natively, and Sol's own backend_config sends a GCP target only bucket= and
  # prefix=sol/<cloud|platform>/<target>.tfstate.
  state_bucket: $STATE_BUCKET

  # GCP's identity declaration. Same capability as AWS's provisioner role (who may
  # enter the install window), provider-native mechanism: an impersonation grant
  # rather than a role ARN. Declared, never inferred, so that "no caller named"
  # cannot come to mean "grant whoever is running Sol".
  provisioner_impersonator: $IMPERSONATOR

  # A disposable qualification target: the postcondition is Absent with nothing
  # billable retained (DEC-033).
  destroy_retention: none

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
    # No create_dns_zone here: the durable root owns the zone (DEC-043) and the var-file
    # says so. An explicit override is how the tfvars and the CLI came to disagree -- two
    # sources for one setting, each individually reasonable, and the override silently won.
    "--var=provisioner_impersonators=[\"$IMPERSONATOR\"]"
}

# ── absence verification: the provider's own answer, not Terraform's ──────────
# The DNS zone is the one thing that must SURVIVE (DEC-042: it is a durable
# prerequisite, and a recreated zone gets new nameservers that silently invalidate
# the delegation). Everything else must be gone, including the service-networking
# peering, which has twice been the abandoned resource in this workstream.
# ── the delegation hand-off, surfaced as early as the zone allows ─────────────
# Attempt 5 captured the nameservers only after `cloud apply` returned, so the human
# step waited behind a ~10 minute stage while the zone had existed for most of it. The
# watcher publishes them the moment Cloud DNS has the zone, overlapping the rest of the
# apply with the registrar work.
start_ns_watcher() {
  (
    for _ in $(seq 1 360); do
      if gcloud dns managed-zones describe "$ZONE_NAME" --project "$PROJECT" \
          --format='value(nameServers)' >"$LOG_DIR/nameservers.txt" 2>/dev/null; then
        : >"$LOG_DIR/nameservers.ready"
        printf '\n[%(%H:%M:%S)T] DELEGATION HAND-OFF READY — paste these four NS records at the registrar, named %s:\n' -1 "$ZONE_LABEL"
        tr ';' '\n' <"$LOG_DIR/nameservers.txt" | sed 's/^/    /'
        break
      fi
      sleep 5
    done
  ) &
  NS_WATCHER=$!
}

# The variables a destroy needs: the same set apply used, with one deliberate exception,
# whether the delegated zone is destroyed with the target. The lifecycle cannot express
# "this resource is durable" (FND-0028), so a faithful product destroy removes the zone --
# and the registrar NS records outside every provider API would then point at a zone that
# no longer exists, with new nameservers on any recreate (DEC-042). KEEP_DNS_ZONE=1
# (default) therefore passes create_dns_zone=false so the zone is not managed by this
# destroy, and the run reports it as residue rather than hiding it. That is a harness
# default, NOT the resolution of DEC-043.
#
# These existed before and were deleted by the refactor that introduced
# reconcile_durable_root, which left the teardown path calling `sol cloud destroy` with no
# variables at all -- a dead safety net in merged code, discovered only by running it.
# That is why the next step is a stub-based state-machine test for this script: the
# harness is part of the qualification system now, and "the teardown works" must be a
# tested claim rather than a memory of a green run.
destroy_vars() {
  local zone_var="create_dns_zone=false"
  [ "${KEEP_DNS_ZONE:-1}" = "0" ] && zone_var="create_dns_zone=true"
  printf '%s\n' \
    "--var-file=$TFVARS" \
    "--var=cluster_name=$CLUSTER" \
    "--var=base_domain=$BASE_DOMAIN" \
    "--var=$zone_var" \
    "--var=provisioner_impersonators=[\"$IMPERSONATOR\"]"
}

# ── durable prerequisites: RECONCILED, never replaced, never destroyed ────────
# The durable root owns the state bucket and the delegated DNS zone, so it is an IaC
# owner and is reconciled to its declared state -- a presence check is not ownership
# (DEC-043). "Ensure it exists" was adequate while the root's only job was to make a
# backend; it is not adequate now that it declares bucket policy and the zone itself.
#
# Two distinct things happen here, and they are not the same operation:
#
#   1. STRUCTURAL: the backend must exist before Terraform can store state in it. That is
#      the one recursion a bootstrap root cannot escape, and it is why a presence check
#      survives at all -- but presence is NOT the contract for the resources themselves.
#   2. RECONCILE: init, plan, apply. Note what this may change: bucket labels and the
#      zone's description. Note what it must never do: replace or destroy either, because
#      a recreated zone gets *different* nameservers -- silently breaking the delegation
#      pasted at the registrar -- and a recreated bucket is the state store for every
#      root. A plan that would replace or destroy therefore stops the run instead of
#      being applied.
reconcile_durable_root() {
  local base=(-backend-config="bucket=$STATE_BUCKET" -backend-config="prefix=bootstrap/gcp")
  local v=(-var="project_id=$PROJECT" -var="region=$REGION" -var="state_bucket=$STATE_BUCKET"
           -var="manage_dns_zone=true" -var="base_domain=$BASE_DOMAIN")

  if ! gcloud storage buckets describe "gs://$STATE_BUCKET" --project "$PROJECT" >/dev/null 2>&1; then
    say "bootstrap: state bucket absent — creating it first (the backend cannot create itself)"
  else
    say "bootstrap: state bucket gs://$STATE_BUCKET present"
  fi

  say "bootstrap: reconciling the durable root against its declared state"
  ( cd "$BOOTSTRAP_ROOT" && timeout "$PHASE_TIMEOUT" terraform init -input=false "${base[@]}" ) \
    >"$LOG_DIR/bootstrap.log" 2>&1 || {
      say "bootstrap FAILED at init — see $LOG_DIR/bootstrap.log"; tail -n 20 "$LOG_DIR/bootstrap.log"; return 1;
    }

  local plan_rc=0
  ( cd "$BOOTSTRAP_ROOT" && timeout "$PHASE_TIMEOUT" terraform plan -input=false -detailed-exitcode \
      -out="$LOG_DIR/durable.tfplan" "${v[@]}" ) >>"$LOG_DIR/bootstrap.log" 2>&1 || plan_rc=$?

  case "$plan_rc" in
    0)
      say "bootstrap: durable root already matches its declared state"
      return 0
      ;;
    1)
      say "bootstrap FAILED at plan — see $LOG_DIR/bootstrap.log"
      tail -n 20 "$LOG_DIR/bootstrap.log"
      return 1
      ;;
  esac

  # It wants changes. Refuse the ones that cannot be reconciled in place.
  ( cd "$BOOTSTRAP_ROOT" && terraform show -no-color "$LOG_DIR/durable.tfplan" ) \
    >"$LOG_DIR/durable.plan.txt" 2>&1 || true
  if grep -qE 'must be replaced|will be destroyed' "$LOG_DIR/durable.plan.txt"; then
    say "bootstrap REFUSED: the durable root's plan would replace or destroy a durable resource."
    say "  A recreated zone gets different nameservers (breaking the registrar delegation) and a"
    say "  recreated bucket is the state store for every root. Review $LOG_DIR/durable.plan.txt;"
    say "  this needs a human decision, not an automatic apply."
    return 1
  fi

  say "bootstrap: applying in-place changes to the durable root (metadata only today)"
  ( cd "$BOOTSTRAP_ROOT" && timeout "$PHASE_TIMEOUT" terraform apply -input=false "$LOG_DIR/durable.tfplan" ) \
    >>"$LOG_DIR/bootstrap.log" 2>&1 || {
      say "bootstrap FAILED at apply — see $LOG_DIR/bootstrap.log"; tail -n 20 "$LOG_DIR/bootstrap.log"; return 1;
    }
  say "bootstrap: durable root reconciled"
}

verify_durable_present() {
  local rc=0
  say "verify: expected PRESENT (durable prerequisites outlive the target)"
  if gcloud storage buckets describe "gs://$STATE_BUCKET" --project "$PROJECT" \
    >"$LOG_DIR/verify-state-bucket.log" 2>&1; then
    say "  ✓ state bucket gs://$STATE_BUCKET present"
  else
    say "  ✗ state bucket gs://$STATE_BUCKET is MISSING — a disposable destroy removed a durable prerequisite"
    rc=1
  fi
  if gcloud dns managed-zones describe "$ZONE_NAME" --project "$PROJECT" \
    >"$LOG_DIR/verify-dns-zone.log" 2>&1; then
    say "  ✓ dns zone $ZONE_NAME present (DEC-042: durable by design)"
  else
    say "  · dns zone $ZONE_NAME not created yet (nothing delegated)"
  fi
  return "$rc"
}

# EXPECTED ABSENT — everything the target owns.
verify_absent() {
  local rc=0
  verify_durable_present || rc=1
  say "verify: expected ABSENT (target-owned; independence from Terraform's exit status)"

  probe_gone() { # name, command...
    local name="$1"; shift
    local log="$LOG_DIR/verify-$name.log"
    # Print the whole evaluation, not just the verdict: which command, what it returned, and
    # the classification that follows. A postcondition that says only "✗ exists" forces the
    # reader to reconstruct the reasoning, and a wrong verdict looks identical to a wrong
    # world.
    local status=0
    if "$@" >"$log" 2>&1; then
      status=0
    else
      status=$?
    fi
    say "    probe $name: exit=$status, output: $(head -1 "$log" 2>/dev/null | cut -c1-90)"
    if [ "$status" = "0" ]; then
      say "  ✗ $name still exists (PRESENT)"
      rc=1
      return
    fi
    # Three states, not two. A non-zero exit is not absence: a permission failure, an
    # expired credential or a transport error all exit non-zero without saying anything
    # about the resource, and reading those as "absent" makes the postcondition that is
    # the last line of defence fail OPEN -- reporting a clean account because it could not
    # read the account. Absence needs evidence of absence; anything else is unknown, and
    # unknown fails the verification.
    if grep -qiE '(not[ -]?found|does not exist|was not found|notFound|404)' "$log"; then
      say "  ✓ $name absent (ABSENT: the provider said not-found)"
    else
      say "  ✗ $name: could NOT determine absence (UNKNOWN: the read failed without reporting not-found)"
      say "      (this is not evidence the resource exists, and not evidence it does not)"
      rc=1
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
  # A read that could not be PARSED is not a read that found usage. Reporting the first
  # as the second sends the operator looking for resources that may not exist, and hides
  # that the verification is inconclusive -- this suite caught exactly that, first run.
  if grep -q 'Traceback' "$LOG_DIR/verify-quota-usage.log" 2>/dev/null; then
    say "  ✗ could NOT read the quota usage — unparsable, which is not evidence of zero"
    return 1
  fi
  if grep -qvE '	0(\.0)?$' "$LOG_DIR/verify-quota-usage.log" 2>/dev/null; then
    say "  ✗ some quota usage is non-zero — read $LOG_DIR/verify-quota.log"
    rc=1
  fi

  return "$rc"
}

destroy() {
  # Destroy needs the same target file and the same variables that apply used, for the
  # same reason: it resolves the provider, the lifecycle and the backend from them.
  # Attempt 5's first teardown failed precisely because the target file had already been
  # deleted by cleanup, and the second because the variables were not passed.
  # Claim the attempt first: this is the single "ensure teardown has happened" owner, and
  # an attempt that fails must not be retried by the EXIT trap behind the operator's back.
  TEARDOWN_ATTEMPTED=1
  local vars
  mapfile -t vars < <(destroy_vars)
  say "teardown: sol cloud destroy $TARGET"
  ( cd "$WORKSPACE" && "$SOL" cloud destroy "$TARGET" --apply "${vars[@]}" ) \
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
  if [ "$KEEP" = "1" ]; then
    say "not tearing down: ${KEEP_REASON:-the delegation boundary is deliberate, not a leak}"
    say "logs: $LOG_DIR"
    return "$rc"
  fi
  # A plan-only run creates nothing, so a failure there must not reach for the
  # teardown path. Every other failure does: a run of this harness that failed is
  # presumed to have possibly created something, and the verification decides.
  if [ "$TEARDOWN_ATTEMPTED" = "0" ] \
    && { [ "$CLOUD_APPLIED" = "1" ] || { [ "$rc" != "0" ] && ! plan_only; }; }; then
    destroy || true
  fi
  say "logs: $LOG_DIR"
  # A plan-only run applied nothing, so there is no teardown verdict to require --
  # demanding one made PLAN_ONLY structurally unable to exit 0.
  if plan_only; then
    rm -f "$TARGET_FILE"
    return "$rc"
  fi
  # The target file is what makes a destroy possible at all. Remove it only once
  # teardown has been VERIFIED; on an unverified teardown keep it and say so, because
  # deleting it is exactly what turned this harness's "unconditional teardown" into no
  # teardown at all during Attempt 5.
  if [ "$TEARDOWN_OK" = "1" ]; then
    rm -f "$TARGET_FILE"
  elif [ "$CLOUD_APPLIED" = "0" ]; then
    rm -f "$TARGET_FILE"
  else
    say "KEEPING $TARGET_FILE — teardown was not verified, and destroy requires this file."
  fi
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

  # Terraform cannot even initialize against a backend that does not exist, so the
  # durable prerequisite is ensured in both modes. PLAN_ONLY still means "no target
  # infrastructure": this only guarantees the bucket, idempotently.
  reconcile_durable_root || return 1

  if plan_only; then
    run cloud-plan "$SOL" cloud plan "$TARGET" "${vars[@]}"
    say "PLAN_ONLY=1: nothing created; target and variables validated"
    return 0
  fi

  CLOUD_APPLIED=1
  start_ns_watcher
  run cloud-apply "$SOL" cloud apply "$TARGET" "${vars[@]}" || return 1

  # Capture the delegation hand-off the moment the zone exists. This is the one
  # value the run cannot produce for itself: the parent zone is managed at a
  # registrar with no API, so a human pastes these four records.
  if [ ! -s "$LOG_DIR/nameservers.txt" ] && ! gcloud dns managed-zones describe "$ZONE_NAME" --project "$PROJECT" \
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
    # Capture, then test: piping into `head -1` would SIGPIPE the lookup and, under
    # `set -o pipefail`, kill the harness in the middle of the delegation wait.
    ns_now="$(dns_ns "$BASE_DOMAIN")"
    if [ -n "$ns_now" ]; then
      say "delegation observed: $(printf '%s' "$ns_now" | tr '\n' ' ')"
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
  write_target   # destroy resolves everything from the target file
  CLOUD_APPLIED=1
  destroy
}

case "${1:-}" in
  cloud)    phase_cloud ;;
  platform) phase_platform ;;
  stop)
    # Stop a recorded run by IDENTITY, then tear down: a TERM does not run the EXIT trap,
    # so stopping without destroying would leave the resources this run created.
    #
    # INFRA-076: the TERM reaches the harness and `sol`, never Terraform or its provider
    # plugins -- Sol runs Terraform in a session of its own and forwards exactly one
    # SIGINT to Terraform's pid, which then stops itself (persisting state, releasing
    # the lock). So wait for the whole group to exit before destroying: a fixed sleep
    # would start the destroy against a lock a live Terraform still holds, which is how
    # Attempt 6 ended in a force-unlock. Never force-unlock; never signal a provider.
    if [ -s "$LOG_DIR/run.pgid" ]; then
      pgid="$(cat "$LOG_DIR/run.pgid")"
      say "stopping the run in $LOG_DIR (process group $pgid)"
      kill -TERM -"$pgid" 2>/dev/null || true
      while kill -0 -"$pgid" 2>/dev/null; do
        say "  waiting for the run (and the Terraform it is stopping) to exit..."
        sleep 5
      done
    else
      say "no run.pgid in $LOG_DIR — nothing recorded to stop"
    fi
    phase_destroy
    ;;
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
