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
# platform install, captures what the cluster actually says, *classifies* the captured
# evidence against the candidate causes, and stops. Classification is not remediation: a
# harness that "tries the likely firewall fix" destroys the experiment it was written to
# perform.
#
# Which invocation installs the platform (H2 of the HARDEN-006 attempt-8 re-scope):
# `sol cloud apply`.
# It opens the install window, applies the cloud root, installs the platform, waits for
# readiness and verifies de-escalation, all in one sequence (`Sol_cli_cloud_apply.execute`,
# reached from `cmd_cloud_tf.ml`'s Apply branch). `sol deploy` is the *application* deploy:
# it never installs a platform, so a failure there is not FND-0010's. There is therefore no
# separate `platform` phase: the discriminator is captured in the `cloud` phase,
# immediately after a failed `sol cloud apply` and before any teardown.
#
# Two prerequisites this harness does NOT yet satisfy, both found by running it (a
# PLAN_ONLY cloud run fails closed on the first, which is the point of having it):
#
#   1. **A state bucket, and no GCP path that creates one.** `sol cloud` refuses to
#      initialize Terraform until the target declares `state_bucket`, because a
#      Terraform root cannot create its own backend. The AWS side provisions the pair
#      from `platform/cloud/aws/bootstrap/`, which is AWS-only (`provider "aws"`,
#      `aws_s3_bucket`, `aws_dynamodb_table`) — so on GCP the bucket is either created
#      once out of band and recorded in the untracked target, or a GCP bootstrap root
#      is authored. GCS needs no lock table.
#   2. **The target's fields, derived from the contract rather than copied from AWS.**
#      `internal/qualification/aws/run8-aws-target.example.yml` is an *AWS* target: it carries
#      `kube_context`, `registry`, four role ARNs and `cluster_endpoint_cidr`, none of
#      which are GCP-shaped. The symmetry here is capability, not configuration: GCP
#      declares one `provisioner_impersonator` where AWS carries a provisioner role
#      ARN, and carries no lock table because GCS serializes state natively. This
#      harness therefore writes only the fields `config.ml`'s target record actually
#      has and the GCP contract requires, and stops at the first missing prerequisite
#      rather than guessing.
#
# Usage:
#   internal/qualification/gcp/live-qual.sh cloud      # preflight, durable reconcile, sol cloud apply
#                                                      #   failure -> FND-0010 discriminator, evidence
#                                                      #              freeze, then teardown (same
#                                                      #              invocation: the cost rule)
#                                                      #   success -> Ready-path evidence + NS hand-off
#   internal/qualification/gcp/live-qual.sh destroy    # evidence freeze (idempotent) + supported
#                                                      #   teardown + post-teardown inventory
#   internal/qualification/gcp/live-qual.sh verify     # post-teardown inventory only (no mutation)
#
# `platform` is refused rather than implemented: this harness has no platform phase, because
# `sol cloud apply` is the platform install.
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
SOL="${SOL:-$ROOT/_build/default/cli/bin/main.exe}"
# Overridable so a test can point the harness at a scratch workspace: the target file is
# written into it, and a suite that writes into the repository cannot assert that nothing
# was left behind.
WORKSPACE="${WORKSPACE:-$ROOT/examples/pluto}"
TFVARS="$ROOT/internal/qualification/gcp/qual-gcp.tfvars"

# The qualification target is generated, not committed (FEAT-100): it is written as a
# whole environment into the workspace's gitignored sol/environments.local.yml, and
# check_no_account_artifacts.sh refuses that file tracked -- the repository's way of
# saying a provisioned-target definition, with its real identities, is scratch. The
# harness owns the file only when it wrote it (the first line says so), refuses to
# overwrite one it did not write, and removes only its own.
#
# Overridable like CLUSTER, and for the same reason: the target names the Terraform
# state objects (`sol/<target>/<layer>.tfstate`), so two attempts that share a key
# share state. `CLUSTER` being unique is not enough when the key is fixed --
# Attempt 8's failed install left the platform root of `qual/gcp/us-central1` with
# 11 resources whose objects no longer exist, and a later attempt reusing that key
# would inherit them as its own starting state instead of producing its own
# specimen (INFRA-082 owns that stale state; it must not be overwritten).
# Give each attempt its own key: TARGET=qual9/gcp/us-central1 ...
TARGET="${TARGET:-qual/gcp/us-central1}"
TARGET_ENV="${TARGET%%/*}"
TARGET_KEY="${TARGET#*/}"
TARGET_FILE="$WORKSPACE/sol/environments.local.yml"
TARGET_MARK="# Written by internal/qualification/gcp/live-qual.sh for $TARGET; removed after a verified teardown."

PROJECT="${PROJECT:-sol-qualification}"
REGION="${REGION:-us-central1}"
BASE_DOMAIN="${BASE_DOMAIN:-qual-gcp.sol-fab.dev}"
PHASE_TIMEOUT="${PHASE_TIMEOUT:-1200}"
DELEGATION_WAIT_MINUTES="${DELEGATION_WAIT_MINUTES:-25}"
LOG_DIR="${LOG_DIR:-/tmp/sol-gcp-qual-$(date +%Y%m%d-%H%M%S)}"
STATE_BUCKET="${STATE_BUCKET:-sol-qualification-tfstate}"
PROFILE_NAME="${PROFILE_NAME:-production-single-region}"
BOOTSTRAP_ROOT="$ROOT/platform/cloud/gcp/bootstrap"

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
    echo "    eval \$(opam env) && dune build cli/bin/main.exe" >&2
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
BUNDLE_ATTEMPTED=0 # whether this invocation froze an evidence bundle
BUNDLE_OK=0       # whether that bundle contains what the runbook promises
# One value with three meanings, because "attempted, neither succeeded nor failed" is not a
# state the install can be in. `none` -> no install in this invocation (a standalone destroy,
# a plan-only run); `succeeded` -> the Ready path; `failed` -> the discriminator's path.
INSTALL_STATE=none
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

# The harness owns sol/environments.local.yml only when it wrote it.
owns_target_file() {
  [ -f "$TARGET_FILE" ] && head -1 "$TARGET_FILE" | grep -qF "live-qual.sh"
}

remove_target() {
  if owns_target_file; then rm -f "$TARGET_FILE"; fi
}

write_target() {
  mkdir -p "$(dirname "$TARGET_FILE")"
  if [ -f "$TARGET_FILE" ] && ! owns_target_file; then
    say "REFUSING: $TARGET_FILE exists and was not written by this harness; move it aside first."
    exit 2
  fi
  cat >"$TARGET_FILE" <<YAML
$TARGET_MARK
$TARGET_ENV:
  targets:
    $TARGET_KEY:
      cluster_name: $CLUSTER
      base_domain: $BASE_DOMAIN
      profile: $PROFILE_NAME
      # NO cluster_issuer, deliberately (H1 of the HARDEN-006 attempt-8 re-scope). Installing a
      # GCP platform through the shared definition is still refused while its ClusterIssuers
      # are Route 53-only (FND-0007), and that refusal is correct and stays: it stops Sol
      # provisioning a platform that looks TLS-wired and cannot issue. INFRA-067 made
      # *destruction* stop evaluating it; installation must keep refusing. This run is not
      # asking the TLS question -- its job is to reach the cert-manager boundary and capture
      # FND-0010's discriminator -- so it asks for a platform without an issuer rather than
      # for one it cannot have.
      letsencrypt_email: $LE_EMAIL
      # Absolute, so it does not depend on how relative paths resolve (BUG-057: from the
      # workspace root).
      terraform_var_file: $TFVARS

      # The durable state backend: provisioned once by ensure_state_bucket() and merely
      # CONSUMED here. state_lock_table is deliberately absent -- GCS serializes state
      # natively, and Sol's own backend_config sends a GCP target only bucket= and
      # prefix=sol/<cloud|platform>/<target>.tfstate.
      state_bucket: $STATE_BUCKET

      # GCP's identity declaration: who may enter the install window, by impersonation.
      # Declared, never inferred, so that "no caller named" cannot come to mean "grant
      # whoever is running Sol". Provider-owned, so it lives in the gcp block (REFAC-098).
      gcp:
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
  say "wrote target $TARGET ($TARGET_FILE)"
}

# No create_dns_zone here: the durable root owns the zone (DEC-043) and the var-file says so.
# An explicit override is how the tfvars and the CLI came to disagree -- two sources for one
# setting, each individually reasonable, and the override silently won.
#
# No provisioner_impersonators either, and the reason is the same one: a target that names
# `provisioner_impersonator` in its `gcp` block is authoritative -- Sol routes it from the
# target (`sol_keys`) -- so passing it here as well would be a second source for one setting.
# This argument list used to carry it *behind a comment*, which ended the printf: the shell
# then ran the line as a command, printed `--var=provisioner_impersonators=[...]: command not
# found`, and dropped the argument (INFRA-080 item C; harmless live, because the target's
# value arrived anyway, and exactly the kind of dead line a reader would trust).
cloud_vars() {
  printf '%s\n' \
    "--var-file=$TFVARS" \
    "--var=cluster_name=$CLUSTER" \
    "--var=base_domain=$BASE_DOMAIN"
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

# ── provider inventory: the provider's own answer, not Terraform's ────────────
#
# Every row is a POSTCONDITION with an observable that establishes it, and the vocabulary is
# PRESENT / ABSENT / UNKNOWN with UNKNOWN always failing:
#
#   PRESENT   the provider still has the thing the postcondition says is gone
#   ABSENT    provider evidence establishes the postcondition (see each probe for which
#             evidence, named in the row's detail)
#   UNKNOWN   the read did not establish anything either way -- never read as ABSENT
#
# Most classes are answered by [provider_probe] below: a describe that returns the object, or
# a list plus the provider's own not-found vocabulary. Three of them cannot be, because after
# a successful teardown their objects are provider-deleted and a describe of a deleted object
# answers ambiguously (Attempts 8 and 9 both captured `PERMISSION_DENIED ... (or it may not
# exist)`); those have their own probes, each naming the observable it uses and preserving the
# raw response beside the verdict.
#
# One tri-state probe. "The read failed" is not "the resource is gone": a permission
# failure, an expired credential or a transport error all exit non-zero without saying
# anything about the resource, and reading those as ABSENT is how a postcondition that is
# the last line of defence fails open -- reporting a clean account because it could not read
# the account. PRESENT / ABSENT / UNKNOWN, and UNKNOWN always fails a postcondition.
#
# The probe command must exit 0 and PRINT what it found, or fail with the provider's own
# not-found vocabulary. One shape covers both kinds this inventory needs:
#   describe <name>    -> exit 0 and prints the object   => PRESENT
#   list --filter=...  -> exit 0 and prints nothing      => ABSENT
provider_probe() { # provider_probe <class> <expect> <command...>
  local class="$1" expect="$2"; shift 2
  local out="$LOG_DIR/inventory-$class.log" err="$LOG_DIR/inventory-$class.stderr" verdict
  # stdout and stderr are kept apart on purpose: the verdict is about what the provider
  # *returned*, and real `gcloud` writes a warning to stderr when a filtered list is empty
  # ("filter keys were not present in any resource"). Merging them made that warning look like
  # an answer, so an empty list read as PRESENT -- observed against the live project.
  if "$@" >"$out" 2>"$err"; then
    if [ -n "$(tr -d '[:space:]' <"$out")" ]; then verdict=PRESENT; else verdict=ABSENT; fi
  # `not[_. -]?found` covers every form the provider actually emits, captured from it:
  #   `NOT_FOUND: Unknown service account. …`            (the underscore form -- the one this
  #                                                       probe used to miss, so a genuine
  #                                                       not-found read as UNKNOWN)
  #   `… The resource 'projects/p/global/networks/x' was not found`
  #   `NOTFOUND:` / `not found`
  # The `-i` above makes the camel-case form unnecessary. Do NOT add alternatives for
  # permission, transport or malformed failures: they are UNKNOWN, and broadening them would
  # fail open -- which is the one thing this probe exists to prevent.
  elif grep -qiE '(not[_. -]?found|does not exist|404|No URLs matched)' "$err" "$out"; then
    verdict=ABSENT
  else
    verdict=UNKNOWN
  fi
  printf '%s\t%s\t%s\t%s\n' \
    "$class" "$verdict" "$expect" "$(head -1 "$err" "$out" 2>/dev/null | cut -c1-100)" >>"$INVENTORY_TSV"
  say "    $class: $verdict"
}

# ── Postconditions that a `describe` cannot answer ───────────────────────────
#
# A verdict is about a POSTCONDITION, never about a command's exit status. Three classes
# need more than "is this object there?" once a teardown has succeeded: the objects are
# provider-deleted, and GCP's answer to a describe of a deleted object is ambiguous --
# `PERMISSION_DENIED: Permission 'iam.serviceAccounts.get' denied on resource (or it may
# not exist)`, which establishes nothing either way. Attempt 8 and Attempt 9 both observed
# that, and both observed the harness refusing to call it absence (correctly). Reading it as
# absence would be the one thing this inventory exists to prevent; the fix is to ask a
# question the provider answers authoritatively.
#
#   class                    postcondition                        observable
#   service-account-*        the identity is not ACTIVE           the project's authoritative
#                                                                 list of active accounts
#   impersonator-binding     the operator holds no USABLE          the identity's active state
#                            impersonation authority on the        (a deleted identity cannot
#                            target's provisioner identity         be impersonated) plus the
#                                                                  identity's policy when it
#                                                                  still exists
#   custom-role              no ACTIVE role of that name           `describe` with the
#                                                                 provider's own `deleted`
#                                                                 marker
#
# The raw response of every read below is preserved in the bundle, so a reviewer sees what
# GCP returned, which rule interpreted it, and why the verdict followed.

verdict_row() { # verdict_row <class> <verdict> <expect> <detail>
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$INVENTORY_TSV"
  say "    $1: $2${4:+ ($4)}"
}

# Postcondition: the target's provisioner identity is no longer active.
# The list is authoritative and answers unambiguously; it fails closed (an unreadable list
# is UNKNOWN, never "no accounts"). The per-account `describe` is kept as raw evidence -- it
# is what Attempt 9's bundle shows, and it is unreadable once the account is deleted.
PROVISIONER_SA_VERDICT=""
probe_service_account() { # probe_service_account <class> <email>
  local class="$1" email="$2"
  local out="$LOG_DIR/inventory-$class.log" err="$LOG_DIR/inventory-$class.stderr" verdict detail=""
  gcloud iam service-accounts describe "$email" --project "$PROJECT" --format='value(email)' \
    >"$LOG_DIR/inventory-$class.describe.log" 2>&1 || true
  if gcloud iam service-accounts list --project "$PROJECT" --format='value(email)' \
       >"$out" 2>"$err"; then
    if grep -qxF "$email" "$out"; then
      verdict=PRESENT; detail="active in the project's service-account list"
    else
      verdict=ABSENT
      # Portable on purpose: this runs on bare CI runners too, where ripgrep is not
      # guaranteed -- and a missing tool would silently take the other branch, which is how
      # the first revision of this line failed there.
      if grep -qE 'PERMISSION_DENIED|NOT_FOUND|Unknown service account' \
           "$LOG_DIR/inventory-$class.describe.log" 2>/dev/null; then
        detail="not in the active list, and its describe is unreadable (deleted identity) — see the raw logs"
      else
        detail="absent from the active list"
      fi
    fi
  else
    verdict=UNKNOWN; detail="the authoritative service-account list could not be read"
  fi
  PROVISIONER_SA_VERDICT="$verdict"
  verdict_row "$class" "$verdict" absent "$detail"
}

# Postcondition: the operator holds no usable impersonation authority over the provisioner
# identity.
#   identity not active -> the grant cannot be exercised: GCP cannot mint a token for a
#     deleted service account, and the SA-level policy is deleted with the identity it was
#     attached to. The rule is named in the detail, and the policy read is attempted anyway
#     so the bundle carries what the provider actually answered. This is the implication the
#     qualification contract establishes for this class; it is pinned by
#     test-live-qual.sh, including the case where the identity is still active.
#   identity active     -> the identity's own policy is the narrowest read: the impersonator's
#     bindings on it, or nothing, or unreadable.
probe_impersonator_binding() { # probe_impersonator_binding <class> <identity-verdict> <email>
  local class="$1" identity_verdict="$2" email="$3"
  local out="$LOG_DIR/inventory-$class.log" err="$LOG_DIR/inventory-$class.stderr" verdict detail=""
  if [ "$identity_verdict" = "ABSENT" ]; then
    gcloud iam service-accounts get-iam-policy "$email" --project "$PROJECT" \
      --flatten='bindings[].members' --filter="bindings.members=$IMPERSONATOR" \
      --format='value(bindings.role)' >"$LOG_DIR/inventory-$class.policy.log" 2>&1 || true
    verdict=ABSENT
    detail="the identity the grant is on is not active, so it cannot be impersonated (raw policy read kept)"
  elif [ "$identity_verdict" = "PRESENT" ]; then
    if gcloud iam service-accounts get-iam-policy "$email" --project "$PROJECT" \
         --flatten='bindings[].members' --filter="bindings.members=$IMPERSONATOR" \
         --format='value(bindings.role)' >"$out" 2>"$err"; then
      if [ -n "$(tr -d '[:space:]' <"$out")" ]; then
        verdict=PRESENT; detail="the impersonator still holds a role on the identity"
      else
        verdict=ABSENT; detail="the identity is active and no impersonator binding remains on it"
      fi
    else
      verdict=UNKNOWN; detail="the identity is active and its policy could not be read"
    fi
  else
    verdict=UNKNOWN; detail="the identity's own state could not be determined"
  fi
  verdict_row "$class" "$verdict" absent "$detail"
}

# Postcondition: no ACTIVE custom role of this name.
# GCP soft-deletes custom roles into an undelete window: `describe` then reports
# `deleted: true`. That is the provider's "deleted" — distinct from an active role and from
# an unreadable one — and it satisfies a teardown postcondition. The raw marker is kept in
# the log rather than hidden, so nothing pretends the object literally vanished.
probe_custom_role() { # probe_custom_role <class> <role-id>
  local class="$1" role_id="$2"
  local out="$LOG_DIR/inventory-$class.log" err="$LOG_DIR/inventory-$class.stderr" verdict detail="" line marker
  if gcloud iam roles describe "$role_id" --project "$PROJECT" --format='value(name,deleted)' \
       >"$out" 2>"$err"; then
    line="$(head -1 "$out")"
    marker="$(printf '%s' "$line" | cut -s -f2 | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
    case "$marker" in
      true)  verdict=ABSENT; detail="provider-deleted (kept in GCP's undelete window): $line" ;;
      *)     verdict=PRESENT; detail="an active custom role of this name exists: $line" ;;
    esac
  elif grep -qiE '(not[_. -]?found|does not exist|was not found|404|No URLs matched)' "$err" "$out"; then
    verdict=ABSENT; detail="not found"
  else
    verdict=UNKNOWN; detail="the role read failed without saying not-found"
  fi
  verdict_row "$class" "$verdict" absent "$detail"
}

# The names below are the GCP root's own (`platform/cloud/gcp/cluster/main.tf`) and the state
# object keys are the backend's own, read from the bucket rather than guessed. A guessed name
# is a probe that can never answer: this harness used to ask for a network named
# "$CLUSTER-vpc" while the root names it "$CLUSTER", so that probe could only ever return
# not-found and reported a vacuous "absent" -- the class FND-0045 named, in the harness.
GCP_ROLE_ID="sol_$(printf '%s' "$CLUSTER" | tr '-' '_')_cluster_access"
GCP_PROVISIONER_SA="$CLUSTER-provisioner@$PROJECT.iam.gserviceaccount.com"

# Quota usage is the cheap global cross-check: usage 0 across the board means the project is
# idle. A read that could not be PARSED is not a read that found usage, and reporting the
# first as the second sends the operator looking for resources that may not exist.
quota_usage() {
  gcloud compute regions describe "$REGION" --project "$PROJECT" \
    --format='csv[no-heading](quotas.metric,quotas.usage)' \
    >"$LOG_DIR/inventory-quota-raw.log" 2>&1 || true
  # The parser decides the verdict, in the same code that reads the values. A bash pattern
  # trying to match a tab-and-zero is one escape away from calling a zero-usage account busy
  # (or the reverse), so the verdict comes from the numbers rather than from a regex dialect.
  python3 - "$LOG_DIR/inventory-quota-raw.log" <<'PY' >"$LOG_DIR/inventory-quota.log" 2>&1 || true
import sys
metrics, usage = open(sys.argv[1]).read().strip().split(",")
want = ["CPUS", "IN_USE_ADDRESSES", "SSD_TOTAL_GB", "DISKS_TOTAL_GB", "INSTANCES"]
read = dict(zip(metrics.split(";"), usage.split(";")))
busy = []
for m in want:
    value = (read.get(m) or "0").strip()
    print(f"{m}\t{value}")
    if float(value or 0) != 0:
        busy.append(m)
print("VERDICT:" + ("PRESENT" if busy else "ABSENT"))
PY
  local verdict
  verdict="$(sed -n 's/^VERDICT://p' "$LOG_DIR/inventory-quota.log" | tail -1)"
  case "${verdict:-}" in
    ABSENT)
      say "    quota: ABSENT (no usage)"
      printf 'quota\tABSENT\tabsent\tall zero\n' >>"$INVENTORY_TSV"
      ;;
    PRESENT)
      say "    quota: PRESENT (some usage is non-zero; read $LOG_DIR/inventory-quota-raw.log)"
      printf 'quota\tPRESENT\tabsent\tnon-zero usage\n' >>"$INVENTORY_TSV"
      ;;
    *)
      # An unparsable read is not a read that found zero.
      say "    quota: UNKNOWN (the usage read could not be parsed, which is not zero)"
      printf 'quota\tUNKNOWN\tabsent\tcould not parse the usage read\n' >>"$INVENTORY_TSV"
      ;;
  esac
}

# The disposable surface the qualification contract names (GKE, Cloud SQL, storage, database,
# network/peering, addresses, disks, load balancers, registry, service accounts, grants) plus
# the two durable prerequisites. ONE list, so the pre-teardown and post-teardown inventories
# cannot drift apart.
inventory() { # inventory <pre|post>
  local mode="$1"
  INVENTORY_TSV="$LOG_DIR/inventory-$mode.tsv"
  : >"$INVENTORY_TSV"
  say "inventory ($mode): provider reads only, no mutation"
  provider_probe gke-cluster    absent  gcloud container clusters describe "$CLUSTER" --region "$REGION" --project "$PROJECT" --format='value(name)'
  provider_probe sql-instance   absent  gcloud sql instances describe "$CLUSTER-postgres" --project "$PROJECT" --format='value(name)'
  provider_probe network        absent  gcloud compute networks describe "$CLUSTER" --project "$PROJECT" --format='value(name)'
  provider_probe subnetwork     absent  gcloud compute networks subnets describe "$CLUSTER-nodes" --region "$REGION" --project "$PROJECT" --format='value(name)'
  provider_probe router         absent  gcloud compute routers describe "$CLUSTER-router" --region "$REGION" --project "$PROJECT" --format='value(name)'
  provider_probe nat            absent  gcloud compute routers nats describe "$CLUSTER-nat" --router "$CLUSTER-router" --region "$REGION" --project "$PROJECT" --format='value(name)'
  provider_probe address-regional absent gcloud compute addresses list --project "$PROJECT" --filter="name~$CLUSTER" --format='value(name)'
  provider_probe address-global absent  gcloud compute addresses list --global --project "$PROJECT" --filter="name~$CLUSTER" --format='value(name)'
  provider_probe disks          absent  gcloud compute disks list --project "$PROJECT" --filter="name~$CLUSTER" --format='value(name)'
  provider_probe forwarding-rules absent gcloud compute forwarding-rules list --project "$PROJECT" --filter="name~$CLUSTER" --format='value(name)'
  provider_probe artifact-registry absent gcloud artifacts repositories describe "$CLUSTER" --location "$REGION" --project "$PROJECT" --format='value(name)'
  # FND/INFRA-080: after teardown this account is provider-deleted, and its `describe` answers
  # `PERMISSION_DENIED ... (or it may not exist)` — unreadable, not absent. The authoritative
  # active-account list is the observable that answers the postcondition.
  probe_service_account service-account-provisioner "$GCP_PROVISIONER_SA"
  provider_probe service-account-loki        absent gcloud iam service-accounts describe "$CLUSTER-loki@$PROJECT.iam.gserviceaccount.com" --project "$PROJECT" --format='value(email)'
  provider_probe service-account-thanos      absent gcloud iam service-accounts describe "$CLUSTER-thanos@$PROJECT.iam.gserviceaccount.com" --project "$PROJECT" --format='value(email)'
  # INFRA-080 B: the provider keeps a deleted custom role in its undelete window and says so
  # with `deleted: true`; that is deleted, not present-and-active.
  probe_custom_role custom-role "$GCP_ROLE_ID"
  provider_probe role-binding   absent  gcloud projects get-iam-policy "$PROJECT" --flatten='bindings[].members' --filter="bindings.members=serviceAccount:$GCP_PROVISIONER_SA" --format='value(bindings.role)'
  # INFRA-080 A: the binding is a policy on an identity. Once that identity is deleted the
  # policy read is unanswerable, so the class asks about the identity's own state (and reads
  # the policy when it still exists), naming the implication in the verdict's detail.
  probe_impersonator_binding impersonator-binding "$PROVISIONER_SA_VERDICT" "$GCP_PROVISIONER_SA"
  provider_probe peering        absent  gcloud compute networks peerings list --project "$PROJECT" --filter="name~servicenetworking" --format='value(name)'
  provider_probe state-bucket   present gcloud storage buckets describe "gs://$STATE_BUCKET" --project "$PROJECT" --format='value(name)'
  provider_probe dns-zone       present gcloud dns managed-zones describe "$ZONE_NAME" --project "$PROJECT" --format='value(name,dnsName)'
  quota_usage
}

# EXPECTED ABSENT — everything the target owns. Judged from the inventory, never from
# Terraform's exit status, and never promoting an unreadable probe into absence.
verify_absent() {
  local rc=0 class verdict expect detail
  inventory post
  while IFS=$'\t' read -r class verdict expect detail; do
    case "$expect:$verdict" in
      absent:ABSENT)   say "  ✓ $class absent" ;;
      present:PRESENT) say "  ✓ $class present (durable prerequisite)" ;;
      absent:PRESENT)  say "  ✗ $class still exists (PRESENT) — $detail"; rc=1 ;;
      present:ABSENT)  say "  ✗ $class is MISSING — a disposable destroy removed a durable prerequisite"; rc=1 ;;
      absent:UNKNOWN)  say "  ✗ $class: could NOT determine absence (UNKNOWN) — $detail"; rc=1 ;;
      present:UNKNOWN) say "  ✗ $class: could NOT be read (UNKNOWN) — $detail"; rc=1 ;;
    esac
  done <"$INVENTORY_TSV"
  return "$rc"
}

# ── the evidence bundle ──────────────────────────────────────────────────────
# Sol prunes its own run directories to the latest 20, shared across commands, so a bundle
# that merely *points at* Sol's run directory can lose the run that mattered (INFRA-075's
# lesson; it is why Attempt 6 could not be replayed offline). Copy the artifacts out. Do not
# change product retention for qualification.
sol_data_dir() {
  if [ -n "${SOL_DATA_DIR:-}" ]; then printf '%s\n' "$SOL_DATA_DIR"; return; fi
  if [ -n "${XDG_DATA_HOME:-}" ]; then printf '%s/sol\n' "$XDG_DATA_HOME"; return; fi
  printf '%s/.local/share/sol\n' "${HOME:-/root}"
}

capture_sol_runs() {
  local src="$1/runs" n
  if [ ! -d "$src" ]; then
    say "  sol runs: no run directory at $src (recorded as absent, not as an error)"
    return 0
  fi
  mkdir -p "$LOG_DIR/sol-runs"
  n="$(find "$src" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
  cp -a "$src/." "$LOG_DIR/sol-runs/" 2>/dev/null || true
  say "  sol runs: copied $n director(ies) from $src"
}

# H3: the Terraform state the provider holds, read straight from the backend object. The key
# is the backend's own (<prefix>/default.tfstate, prefix = sol/<target>/<layer>.tfstate),
# verified against the bucket rather than guessed -- the same rule as the provider names.
# Read-only: no init, no lock, no mutation, nothing written into the trees.
capture_state_object() { # <name> <object-key>
  # Separate `local` statements on purpose: bash expands every right-hand side of a single
  # `local` before assigning any of them, so `local name="$1" out="...$name..."` is an
  # unbound-variable error under `set -u`.
  local name="$1"
  local key="$2"
  local out="$LOG_DIR/state/$name.tfstate"
  mkdir -p "$LOG_DIR/state"
  if gcloud storage cat "gs://$STATE_BUCKET/$key" --project "$PROJECT" \
      >"$out" 2>"$LOG_DIR/state/$name.stderr"; then
    if [ "$(head -c2 "$out" | od -An -tx1 | tr -d ' \n')" = "1f8b" ]; then
      gzip -dc "$out" >"$out.json" 2>/dev/null || true
      say "  state $name: captured (gzip); readable copy $name.tfstate.json"
    else
      say "  state $name: captured"
    fi
  elif grep -qiE 'not.?found|404|No URLs matched|No such object' "$LOG_DIR/state/$name.stderr"; then
    say "  state $name: no object (the root has never been applied) — recorded as absent"
  else
    say "  state $name: COULD NOT READ (UNKNOWN) — see $LOG_DIR/state/$name.stderr"
  fi
}

capture_terraform_state() {
  say "capturing Terraform state (read-only backend reads)"
  capture_state_object cloud    "sol/$TARGET/cloud.tfstate/default.tfstate"
  capture_state_object platform "sol/$TARGET/platform.tfstate/default.tfstate"
  # The durable root's state, for attribution only: it is not part of the disposable target
  # and this harness never destroys it.
  capture_state_object durable  "bootstrap/gcp/default.tfstate"
}

artifact_status() { if [ -s "$1" ]; then printf 'present (%s bytes)\n' "$(wc -c <"$1" | tr -d ' ')"; else printf 'MISSING\n'; fi; }

# The bundle's own index, so "does this bundle contain what the runbook promised?" is a
# readable answer rather than a directory listing someone has to interpret.
bundle_manifest() {
  local m="$LOG_DIR/evidence-manifest.txt" f
  {
    printf 'evidence bundle: %s\n' "$LOG_DIR"
    printf 'target: %s  project: %s  region: %s  revision: %s\n' \
      "$TARGET" "$PROJECT" "$REGION" "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf 'cluster: %s\n\n' "$CLUSTER"
    printf 'sol run evidence .......... %s run director(ies)\n' "$(find "$LOG_DIR/sol-runs" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
    printf 'terraform state (cloud) ... %s\n' "$(artifact_status "$LOG_DIR/state/cloud.tfstate")"
    printf 'terraform state (platform)  %s\n' "$(artifact_status "$LOG_DIR/state/platform.tfstate")"
    printf 'terraform state (durable) . %s\n' "$(artifact_status "$LOG_DIR/state/durable.tfstate")"
    printf 'inventory (pre-teardown) .. %s\n' "$(artifact_status "$LOG_DIR/inventory-pre.tsv")"
    printf 'inventory (post-teardown) . %s\n' "$(artifact_status "$LOG_DIR/inventory-post.tsv")"
    printf 'discriminator class ....... %s\n' "$(artifact_status "$LOG_DIR/fnd0010-classification.txt")"
    printf 'discriminator probes ...... %s file(s)\n' "$(find "$LOG_DIR" -maxdepth 1 -name 'fnd0010-*.log' 2>/dev/null | wc -l | tr -d ' ')"
    printf '\nphase transcripts:\n'
    for f in "$LOG_DIR"/*.log; do [ -e "$f" ] || continue; printf '  %s\n' "$(basename "$f")"; done
  } >"$m"
  say "evidence manifest: $m"
}

# The bundle is part of the run's product, so its completeness is checked rather than
# assumed: a missing member is reported by name and turns the attempt's exit code non-zero.
# Which members are required depends on what this invocation did -- the discriminator's
# classification exists only where the install failed, the Ready-path evidence only where it
# succeeded, and the post-teardown inventory only after a teardown.
verify_bundle() {
  local missing=0 member
  local required=( "state/cloud.tfstate" "state/platform.tfstate" "inventory-pre.tsv"
                   "evidence-manifest.txt" )
  [ "$TEARDOWN_ATTEMPTED" = "1" ] && required+=( "inventory-post.tsv" )
  # The two paths carry different evidence, and demanding both would report every run as
  # incomplete: a failed install produces the discriminator and no Ready-path lines.
  case "$INSTALL_STATE" in
    failed)    required+=( "fnd0010-classification.txt" ) ;;
    succeeded) required+=( "ready-phases.txt" ) ;;
    none) : ;;
  esac
  for member in "${required[@]}"; do
    if [ ! -s "$LOG_DIR/$member" ]; then
      say "  ✗ bundle member missing or empty: $member"
      missing=1
    fi
  done
  if [ -z "$(find "$LOG_DIR/sol-runs" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
    # Sol's run evidence is the artifact its own 20-run retention would delete first.
    say "  ✗ bundle member missing: sol-runs/ (no Sol run directory was copied)"
    missing=1
  fi
  if [ "$missing" = "0" ]; then
    BUNDLE_OK=1
  else
    BUNDLE_OK=0
    say "  the evidence bundle is INCOMPLETE — this attempt is not a conformant run"
  fi
  return "$missing"
}

freeze_evidence() {
  say "freezing the evidence bundle (before any teardown)"
  BUNDLE_ATTEMPTED=1
  capture_terraform_state
  capture_sol_runs "$(sol_data_dir)"
  bundle_manifest
  verify_bundle || true
}

# H6: what the provider holds at the moment of the outcome, before anything is destroyed.
# This is attribution evidence -- it answers "what existed when it broke", which Sol's own
# transcript cannot -- and deliberately not an ownership model: nothing here feeds the
# product and nothing is reconciled from it.
capture_pre_teardown_inventory() {
  say "capturing the pre-teardown provider inventory (attribution evidence)"
  inventory pre
  say "  pre-teardown inventory: $INVENTORY_TSV"
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
    say "teardown NOT verified: resources remain — see $LOG_DIR/inventory-*.tsv and inventory-*.log"
    TEARDOWN_OK=0
  fi
  # The post-teardown inventory is part of the bundle, so the manifest is rewritten now that it
  # exists -- otherwise it records "MISSING" for an artifact captured moments ago -- and the
  # bundle is checked again with the teardown's members included. Both happen on either verdict:
  # a bundle that is accurate about a failed teardown is what a later reader needs most.
  bundle_manifest
  verify_bundle || true
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
    remove_target
    return "$rc"
  fi
  # The target file is what makes a destroy possible at all. Remove it only once
  # teardown has been VERIFIED; on an unverified teardown keep it and say so, because
  # deleting it is exactly what turned this harness's "unconditional teardown" into no
  # teardown at all during Attempt 5.
  if [ "$TEARDOWN_OK" = "1" ]; then
    remove_target
  elif [ "$CLOUD_APPLIED" = "0" ]; then
    remove_target
  else
    say "KEEPING $TARGET_FILE — teardown was not verified, and destroy requires this file."
  fi
  # Only an attempted-but-unverified teardown turns the exit code into a failure. A run that
  # never created anything (a refused subcommand, a usage error) has no teardown verdict to
  # demand, and forcing one there would report a harness error as a qualification failure.
  if [ "$TEARDOWN_ATTEMPTED" = "1" ] && [ "$TEARDOWN_OK" != "1" ]; then rc=1; fi
  if [ "$BUNDLE_ATTEMPTED" = "1" ] && [ "$BUNDLE_OK" != "1" ]; then rc=1; fi
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
  INSTALL_STATE=succeeded
  start_ns_watcher
  if ! run cloud-apply "$SOL" cloud apply "$TARGET" "${vars[@]}"; then
    INSTALL_STATE=failed
    # H2: `sol cloud apply` is the invocation that installs the cloud root *and* the
    # platform (see the header). Its failure here is the boundary this run exists for, so
    # the discriminator is captured NOW -- immediately, while the cluster still exists, and
    # before the EXIT trap tears the target down. A later phase cannot do it: the failure
    # ends this phase, and there is no `sol deploy` phase to fall back to (the application
    # deploy is not a platform install, so a failure there would say nothing about
    # FND-0010).
    say "cloud apply failed -- capturing the discriminator before any teardown"
    capture_fnd0010
    capture_pre_teardown_inventory
    freeze_evidence
    return 1
  fi

  capture_ready_evidence

  # Capture the delegation hand-off the moment the zone exists. This is the one
  # value the run cannot produce for itself: the parent zone is managed at a
  # registrar with no API, so a human pastes these four records.
  if [ ! -s "$LOG_DIR/nameservers.txt" ] && ! gcloud dns managed-zones describe "$ZONE_NAME" --project "$PROJECT" \
    --format='value(nameServers)' >"$LOG_DIR/nameservers.txt" 2>"$LOG_DIR/nameservers.err"; then
    say "could not read the zone's nameservers — the delegation half cannot proceed"
    capture_pre_teardown_inventory
    freeze_evidence
    return 1
  fi
  say "authoritative nameservers for $BASE_DOMAIN (paste these at Squarespace as NS records named 'qual-gcp'):"
  tr ';' '\n' <"$LOG_DIR/nameservers.txt" | sed 's/^/    /'

  # The delegation boundary keeps the substrate alive between two commands, so the bundle is
  # frozen here rather than at teardown: an operator who stops at the hand-off still has the
  # evidence, and `destroy` freezes it again (idempotently) before it tears anything down.
  capture_pre_teardown_inventory
  freeze_evidence

  # Wait — bounded — for the delegation to become visible. The zone is already delegated
  # (DEC-042), so this resolves on the first iteration in practice; it stays bounded because
  # billable infrastructure exists for its duration, and it always reports where it is.
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
  say "records at Squarespace, then run: CLUSTER=$CLUSTER ... live-qual.sh destroy"
  KEEP=1
  return 0
}


# ── FND-0010: the discriminator, captured before anything is remediated ───────
# The check's own container output decides the cause; everything else corroborates it. Four
# candidate causes were plausible from the desk analysis (webhook reachability, the webhook's
# CA bundle, CRD/API discovery, scheduling) and only the captured evidence can choose, so this
# captures all of them and then *classifies* -- it does not assume reachability, and it does
# not remediate. Classification happens after capture, from the files, so a wrong
# classification cannot cost the bundle.
cluster_describable() {
  local name
  name="$(gcloud container clusters describe "$CLUSTER" --region "$REGION" --project "$PROJECT" \
      --format='value(name)' 2>/dev/null)" && [ -n "$name" ]
}

kube_capture() { # kube_capture <name> <command...>
  local name="$1"; shift
  "$@" >"$LOG_DIR/$name.log" 2>&1 || true
  say "  captured $name.log ($(wc -l <"$LOG_DIR/$name.log" | tr -d ' ') lines)"
}

kubeconfig_for_cluster() {
  gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" --project "$PROJECT" \
    >"$LOG_DIR/kubeconfig.log" 2>&1 || true
}

capture_fnd0010() {
  say "capturing FND-0010 discriminator evidence (no remediation)"
  if ! cluster_describable; then
    say "  cluster is not describable — the platform stage cannot have run; nothing to probe"
    return 0
  fi
  kubeconfig_for_cluster
  kube_capture fnd0010-startupapicheck-logs kubectl -n cert-manager logs \
    job/cert-manager-startupapicheck --all-containers --tail=-1
  kube_capture fnd0010-events  kubectl -n cert-manager get events --sort-by=.lastTimestamp
  kube_capture fnd0010-job     kubectl -n cert-manager describe job cert-manager-startupapicheck
  kube_capture fnd0010-job-status kubectl -n cert-manager get job cert-manager-startupapicheck -o json
  kube_capture fnd0010-pods    kubectl -n cert-manager get pods -o wide
  kube_capture fnd0010-objects kubectl -n cert-manager get deploy,svc,sa,issuer,clusterissuer -o wide
  kube_capture fnd0010-webhook-target-port kubectl -n cert-manager get svc cert-manager-webhook \
    -o jsonpath='{.spec.ports[*].targetPort}'
  kube_capture fnd0010-webhook-endpoints kubectl -n cert-manager get endpoints cert-manager-webhook -o wide
  kube_capture fnd0010-webhook-config kubectl get validatingwebhookconfiguration cert-manager-webhook -o yaml
  # FND-0010 follow-up: the first discriminator could say "the caBundle was never injected"
  # but not *why* -- it captured neither the CA the webhook pod writes nor the injector's
  # own view. Both are read-only, and both are needed to tell "the CA secret never appeared"
  # apart from "it appeared and cainjector did not inject it", which are different fixes.
  # The Secret is captured by metadata and key names only: enough to answer existence, type
  # and age, without copying key material into the evidence bundle.
  kube_capture fnd0010-cainjector-logs kubectl -n cert-manager logs deploy/cert-manager-cainjector --tail=-1
  kube_capture fnd0010-controller-logs kubectl -n cert-manager logs deploy/cert-manager --tail=-1
  kube_capture fnd0010-webhook-logs kubectl -n cert-manager logs deploy/cert-manager-webhook --tail=-1
  kube_capture fnd0010-ca-secret kubectl -n cert-manager get secret cert-manager-webhook-ca \
    -o jsonpath='{.metadata.name} type={.type} created={.metadata.creationTimestamp} keys={.data}'
  kube_capture fnd0010-tls-secret kubectl -n cert-manager get secret cert-manager-webhook-tls \
    -o jsonpath='{.metadata.name} type={.type} created={.metadata.creationTimestamp} keys={.data}'
  # What the Attempt 10 re-analysis had to reconstruct by hand, and could not: the Job's *pod*
  # as an object. Kubernetes events carry ages, and a single Created/Started pair cannot tell a
  # first start from a restart -- pod YAML carries metadata.creationTimestamp, spec.nodeName and
  # containerStatuses (state, lastState, startedAt, finishedAt, restartCount), which is the
  # difference between "the container started late" and "the container ran its full window and
  # was restarted". Attempt 10's first reading got this wrong; the capture removes the excuse.
  kube_capture fnd0010-startupapicheck-pod kubectl -n cert-manager get pods \
    -l job-name=cert-manager-startupapicheck -o yaml
  # Leader election is the layer *under* the CA injection, and the actual Attempt 10 failure was
  # here: the chart creates its leaderelection Role/RoleBinding in
  # `global.leaderElection.namespace` (kube-system by default) and points both components at it,
  # and GKE Autopilot denies writing there. Capture the objects and the resulting leases in both
  # namespaces -- read-only, and it turns "no caBundle" into a named cause.
  kube_capture fnd0010-rbac-cert-manager kubectl -n cert-manager get role,rolebinding -o name
  kube_capture fnd0010-rbac-kube-system kubectl -n kube-system get role,rolebinding -o name
  kube_capture fnd0010-leases-cert-manager kubectl -n cert-manager get leases -o wide
  kube_capture fnd0010-leases-kube-system kubectl -n kube-system get leases -o name
  kube_capture fnd0010-certificates kubectl -n cert-manager get certificates,issuers,clusterissuers -o wide
  kube_capture fnd0010-nodes   kubectl get nodes -o wide
  kube_capture fnd0010-firewall-rules gcloud compute firewall-rules list --project "$PROJECT" \
    --filter="name~$CLUSTER" \
    --format='table(name,sourceRanges.list(),allowed[].map().firewall_rule().list(),targetTags.list())'
  kube_capture fnd0010-master-cidr gcloud container clusters describe "$CLUSTER" \
    --region "$REGION" --project "$PROJECT" --format='value(privateClusterConfig.masterIpv4CidrBlock)'
  classify_fnd0010
}

classify_fnd0010() {
  local out="$LOG_DIR/fnd0010-classification.txt"
  local job_log="$LOG_DIR/fnd0010-job.log" events="$LOG_DIR/fnd0010-events.log"
  local check_log="$LOG_DIR/fnd0010-startupapicheck-logs.log"
  {
    printf 'classification: '
    # Ordered with the *falsifying* signatures first: an x509 or API-discovery failure is not a
    # reachability failure, and reading either as one is exactly the error this run exists to
    # prevent. Each alternative is a literal string from the captured evidence. No match, or no
    # evidence at all, is UNKNOWN -- never a default of "reachability".
    if grep -qiE 'managed-namespaces-limitation|leader election record|cannot create resource "leases"' \
        "$LOG_DIR/fnd0010-controller-logs.log" "$LOG_DIR/fnd0010-cainjector-logs.log" 2>/dev/null; then
      # The specific, reversible cause found by Attempt 10's re-analysis: cert-manager's
      # components cannot write the leader-election Lease where they look for it (the chart
      # default is kube-system, which Autopilot manages). First, because when it is present it
      # *is* the cause -- an un-injected caBundle is its consequence, not a rival explanation.
      printf 'LEADER_ELECTION_DENIED\n'
    elif grep -qiE 'x509|unknown authority|certificate signed by unknown|tls: failed to verify' \
        "$check_log" "$job_log" 2>/dev/null; then
      printf 'TLS_CA_OR_CERTIFICATE\n'
    elif grep -qiE 'no matches for kind|could not find the requested resource|failed to discover|unable to retrieve the complete list of server APIs' \
        "$check_log" "$job_log" 2>/dev/null; then
      printf 'CRD_OR_API_DISCOVERY\n'
    elif grep -qiE 'FailedScheduling|Unschedulable|Insufficient (cpu|memory)|no nodes available' \
        "$events" "$LOG_DIR/fnd0010-pods.log" 2>/dev/null; then
      printf 'SCHEDULING\n'
    elif grep -qiE 'forbidden|cannot create resource|is not allowed to' "$check_log" "$job_log" 2>/dev/null; then
      printf 'RBAC\n'
    elif grep -qiE 'context deadline exceeded|dial tcp|i/o timeout|connection refused|no route to host' \
        "$check_log" "$job_log" 2>/dev/null; then
      printf 'WEBHOOK_REACHABILITY\n'
    else
      printf 'UNKNOWN\n'
    fi
    printf '\n-- why (matching lines; empty means the signature was not in the captured evidence) --\n'
    grep -hiE 'managed-namespaces-limitation|leader election record|cannot create resource "leases"|x509|unknown authority|certificate signed by unknown|tls: failed to verify|no matches for kind|could not find the requested resource|failed to discover|forbidden|cannot create resource|context deadline exceeded|dial tcp|i/o timeout|connection refused|no route to host|FailedScheduling|Unschedulable|Insufficient (cpu|memory)' \
      "$check_log" "$job_log" "$events" "$LOG_DIR/fnd0010-pods.log" \
      "$LOG_DIR/fnd0010-controller-logs.log" "$LOG_DIR/fnd0010-cainjector-logs.log" 2>/dev/null | head -20 || true
    printf '\n-- corroboration --\n'
    printf 'webhook targetPort: %s\n' "$(head -1 "$LOG_DIR/fnd0010-webhook-target-port.log" 2>/dev/null)"
    printf 'webhook endpoints : %s\n' "$(head -1 "$LOG_DIR/fnd0010-webhook-endpoints.log" 2>/dev/null)"
    printf 'master CIDR       : %s\n' "$(head -1 "$LOG_DIR/fnd0010-master-cidr.log" 2>/dev/null)"
    printf 'firewall rules:\n'
    sed 's/^/  /' "$LOG_DIR/fnd0010-firewall-rules.log" 2>/dev/null | head -10 || true
    printf '\nThis is a classification of the captured evidence, not a conclusion. A run whose\n'
    printf 'classification is UNKNOWN, or which contradicts the reachability hypothesis, stops\n'
    printf 'here: remediation is a separate authorization.\n'
  } >"$out" 2>&1
  say "discriminator classification: $out"
  sed -n '1p' "$out"
}

# The success path's evidence. Here the platform install returned success, so the check that
# fails otherwise is expected to have SUCCEEDED -- capturing that is the positive control that
# makes a failure classification meaningful.
capture_ready_evidence() {
  say "capturing Ready-path evidence (the platform install returned success)"
  grep -E 'lifecycle phase|bootstrap-access-remove|Provisioned endpoints|^Done' \
    "$LOG_DIR/cloud-apply.log" >"$LOG_DIR/ready-phases.txt" 2>/dev/null || true
  say "  phase lines: $LOG_DIR/ready-phases.txt"
  if ! cluster_describable; then
    say "  cluster is not describable — no cluster-side evidence to capture"
    return 0
  fi
  kubeconfig_for_cluster
  kube_capture ready-pods kubectl get pods -A -o wide
  kube_capture ready-startupapicheck-status kubectl -n cert-manager get job cert-manager-startupapicheck -o json
  kube_capture ready-startupapicheck-logs kubectl -n cert-manager logs \
    job/cert-manager-startupapicheck --all-containers --tail=-1
  if grep -q '"succeeded": 1' "$LOG_DIR/ready-startupapicheck-status.log" 2>/dev/null; then
    say "  startupapicheck: Succeeded (the check ran and passed)"
  else
    say "  startupapicheck: not observed as Succeeded — read $LOG_DIR/ready-startupapicheck-status.log"
  fi
}

phase_destroy() {
  write_target   # destroy resolves everything from the target file
  CLOUD_APPLIED=1
  # The bundle must be complete before the supported teardown starts. Both calls are
  # idempotent: the cloud phase already captured them when it got this far, and capturing
  # again keeps the pre-teardown inventory as close to the teardown as it can be.
  capture_pre_teardown_inventory
  freeze_evidence
  destroy
}


case "${1:-}" in
  cloud)    phase_cloud ;;
  platform)
    say "no platform phase: 'sol cloud apply' installs the platform, and this harness captures"
    say "FND-0010's discriminator in the cloud phase (see the header). Run: live-qual.sh cloud"
    exit 2
    ;;
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
    # The no-cleanup state is set BEFORE the check, because `exit` cannot run code after it:
    # with KEEP set later, a *failing* verify fell through to cleanup's "a failed run is
    # presumed to have created something" rule and called destroy -- recorded live, before
    # Attempt 8's Phase 0 was allowed to run (`internal/qualification/
    # 2026-09-25-gcp-attempt8-phase0-stop.md`). `verify` is read-only whether it passes or
    # fails; that is an invariant, not a property of one branch.
    KEEP=1
    KEEP_REASON="verify does not mutate; nothing to tear down"
    if verify_absent; then say "verify: absent"; else say "verify: resources remain"; exit 1; fi
    ;;
  *)
    sed -n '2,78p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
