#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SOL="${SOL:-$ROOT/_build/default/cli/bin/main.exe}"
WORKSPACE="${WORKSPACE:-$ROOT/examples/pluto}"
TFVARS="$ROOT/internal/qualification/gcp/qual-gcp.tfvars"
OBSERVER="${OBSERVER:-$ROOT/internal/qualification/gcp/observer.py}"

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
RUN_KUBECONFIG="$LOG_DIR/run-kubeconfig.yaml"
export KUBECONFIG="$RUN_KUBECONFIG"
STATE_BUCKET="${STATE_BUCKET:-sol-qualification-tfstate}"
PROFILE_NAME="${PROFILE_NAME:-production-single-region}"
CLUSTER_ISSUER="${CLUSTER_ISSUER:-letsencrypt-staging}"
APP_TAG="${APP_TAG:-qual-$(date -u +%Y%m%d-%H%M%S)}"
export APP_TAG
BOOTSTRAP_ROOT="$ROOT/platform/cloud/gcp/bootstrap"

case "${1:-}" in
  cloud | platform | app)
    CLUSTER="${CLUSTER:?Set CLUSTER to a unique cluster name for this run, e.g. sol-qual-gcp-5}"
    IMPERSONATOR="${IMPERSONATOR:?Set IMPERSONATOR to the calling identity, e.g. user:you@example.com}"
    LE_EMAIL="${LE_EMAIL:?Set LE_EMAIL to an ACME contact address}"
    ;;
  destroy | verify | "")
    if [ -n "${1:-}" ]; then
      CLUSTER="${CLUSTER:?Set CLUSTER to the cluster name to check}"
    fi
    ;;
esac

ZONE_NAME="$(printf '%s' "$BASE_DOMAIN" | tr '.' '-')"
ZONE_LABEL="${BASE_DOMAIN%%.*}"

say() {
  local line
  printf -v line '[%(%H:%M:%S)T] %s' -1 "$*"
  printf '%s\n' "$line"
  if [ -n "${SAY_LOG:-}" ]; then
    printf '%s\n' "$line" >>"$SAY_LOG" 2>/dev/null || true
  fi
}

dns_ns() {
  local name="$1" out
  out="$(curl -s -H 'accept: application/dns-json' \
      "https://dns.google/resolve?name=$name&type=NS" 2>/dev/null \
    | python3 -c "import sys,json;print('\n'.join(sorted(a.get('data','') for a in json.load(sys.stdin).get('Answer',[]))))" 2>/dev/null)"
  if [ -n "$out" ]; then printf '%s\n' "$out"; else dig +short NS "$name" 2>/dev/null || true; fi
}

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
  local canonical
  canonical="$(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{ if (!found) { print $2; found = 1 } }')"
  if [ "$(cd "$canonical" && pwd -P)" = "$(cd "$ROOT" && pwd -P)" ] && [ "${ALLOW_CANONICAL:-0}" != "1" ]; then
    echo "✗ refusing to run in the canonical checkout ($ROOT)." >&2
    echo "  Run from a worktree, or set ALLOW_CANONICAL=1 if you own this checkout." >&2
    exit 2
  fi
}
assert_environment

if [ "${1:-}" != "verify" ]; then
  [ -x "$SOL" ] || {
    echo "✗ CLI not built at $SOL" >&2
    echo "  Build it in this checkout so the attempt is identifiable by commit:" >&2
    echo "    eval \$(opam env) && dune build cli/bin/main.exe" >&2
    exit 2
  }
fi

mkdir -p "$LOG_DIR"
SAY_LOG="$LOG_DIR/harness.log"
say "environment: work tree $ROOT, revision $(git -C "$ROOT" rev-parse --short HEAD)"
echo "$$" >"$LOG_DIR/run.pid"
ps -o pgid= -p "$$" 2>/dev/null | tr -d " " >"$LOG_DIR/run.pgid" || true
DB_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
export TF_VAR_db_password="$DB_PASSWORD"

KEEP=0
BUNDLE_ATTEMPTED=0
BUNDLE_OK=0
INSTALL_STATE=none
APP_STATE=none
CLOUD_APPLIED=0
TEARDOWN_ATTEMPTED=0

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
      letsencrypt_email: $LE_EMAIL
      cluster_issuer: $CLUSTER_ISSUER
      terraform_var_file: $TFVARS

      state_bucket: $STATE_BUCKET

      gcp:
        project_id: $PROJECT
        provisioner_impersonator: $IMPERSONATOR

      destroy_retention: none

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

cloud_vars() {
  printf '%s\n' \
    "--var-file=$TFVARS" \
    "--var=cluster_name=$CLUSTER" \
    "--var=base_domain=$BASE_DOMAIN"
}

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

disk_quota_record() {
  local raw="$LOG_DIR/disk-quota.json"
  if ! gcloud compute regions describe "$REGION" --project "$PROJECT" --format=json \
      >"$raw" 2>"$LOG_DIR/disk-quota.stderr"; then
    printf 'disk-quota\tUNKNOWN\tprovider read failed: %s\n' \
      "$(head -1 "$LOG_DIR/disk-quota.stderr" 2>/dev/null | cut -c1-100)" >>"$INVENTORY_TSV"
    say "    disk-quota: UNKNOWN (provider read failed)"
    return 0
  fi
  python3 - "$raw" "$INVENTORY_TSV" <<'PYQUOTA'
import json, pathlib, sys
raw, tsv = sys.argv[1], sys.argv[2]
def record(verdict, detail):
    pathlib.Path(tsv).open('a').write(f'disk-quota\t{verdict}\t{detail}\n')
    print(f'    disk-quota: {verdict} ({detail})')
try:
    payload = json.load(open(raw))
except Exception as exc:
    record('UNKNOWN', f'unparseable: {exc}')
    sys.exit(0)
quota = next((q for q in payload.get('quotas', []) if q.get('metric') == 'SSD_TOTAL_GB'), None)
if quota is None:
    record('UNKNOWN', 'SSD_TOTAL_GB not reported')
    sys.exit(0)
limit, used = int(quota.get('limit', 0)), int(quota.get('usage', 0))
record('PRESENT', f'SSD_TOTAL_GB limit={limit} usage={used} free={limit - used}')
PYQUOTA
}

provider_probe() {
  local class="$1" expect="$2"; shift 2
  local out="$LOG_DIR/inventory-$class.log" err="$LOG_DIR/inventory-$class.stderr" verdict
  if "$@" >"$out" 2>"$err"; then
    if [ -n "$(tr -d '[:space:]' <"$out")" ]; then verdict=PRESENT; else verdict=ABSENT; fi
  elif grep -qiE '(not[_. -]?found|does not exist|404|No URLs matched)' "$err" "$out"; then
    verdict=ABSENT
  else
    verdict=UNKNOWN
  fi
  printf '%s\t%s\t%s\t%s\n' \
    "$class" "$verdict" "$expect" "$(head -1 "$err" "$out" 2>/dev/null | cut -c1-100)" >>"$INVENTORY_TSV"
  say "    $class: $verdict"
}

verdict_row() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$INVENTORY_TSV"
  say "    $1: $2${4:+ ($4)}"
}

PROVISIONER_SA_VERDICT=""
probe_service_account() {
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

probe_impersonator_binding() {
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

probe_custom_role() {
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

GCP_ROLE_ID="sol_$(printf '%s' "$CLUSTER" | tr '-' '_')_cluster_access"
GCP_PROVISIONER_SA="$CLUSTER-provisioner@$PROJECT.iam.gserviceaccount.com"

quota_usage() {
  gcloud compute regions describe "$REGION" --project "$PROJECT" \
    --format='csv[no-heading](quotas.metric,quotas.usage)' \
    >"$LOG_DIR/inventory-quota-raw.log" 2>&1 || true
  local instances_json="" disks_json="" snapshots_json="" sql_json="" addresses_json=""
  instances_json="$(gcloud compute instances list --project "$PROJECT" --format=json 2>/dev/null || printf '[]')"
  disks_json="$(gcloud compute disks list --project "$PROJECT" --format=json 2>/dev/null || printf '[]')"
  snapshots_json="$(gcloud compute snapshots list --project "$PROJECT" --format=json 2>/dev/null || printf '[]')"
  sql_json="$(gcloud sql instances list --project "$PROJECT" --format=json 2>/dev/null || printf '[]')"
  addresses_json="$(gcloud compute addresses list --project "$PROJECT" --format=json 2>/dev/null || printf '[]')"
  printf '%s' "$instances_json" >"$LOG_DIR/inventory-quota-instances.json"
  printf '%s' "$disks_json" >"$LOG_DIR/inventory-quota-disks.json"
  printf '%s' "$snapshots_json" >"$LOG_DIR/inventory-quota-snapshots.json"
  printf '%s' "$sql_json" >"$LOG_DIR/inventory-quota-sql.json"
  printf '%s' "$addresses_json" >"$LOG_DIR/inventory-quota-addresses.json"
  python3 - "$LOG_DIR/inventory-quota-raw.log" "$LOG_DIR/inventory-quota-instances.json" \
    "$LOG_DIR/inventory-quota-disks.json" "$LOG_DIR/inventory-quota-snapshots.json" \
    "$LOG_DIR/inventory-quota-sql.json" "$LOG_DIR/inventory-quota-addresses.json" \
    <<'PY' >"$LOG_DIR/inventory-quota.log" 2>&1 || true
import json
import sys


def count(path):
    try:
        return len(json.loads(open(path).read() or "[]"))
    except Exception:
        return None


metrics, usage = open(sys.argv[1]).read().strip().split(",")
owners = {
    "CPUS": ("instances", count(sys.argv[2])),
    "INSTANCES": ("instances", count(sys.argv[2])),
    "IN_USE_ADDRESSES": ("addresses", count(sys.argv[6])),
    "SSD_TOTAL_GB": ("disks, snapshots and SQL instances", sum(
        value or 0 for value in (count(sys.argv[3]), count(sys.argv[4]), count(sys.argv[5])))),
    "DISKS_TOTAL_GB": ("disks", count(sys.argv[3])),
}
want = ["CPUS", "IN_USE_ADDRESSES", "SSD_TOTAL_GB", "DISKS_TOTAL_GB", "INSTANCES"]
read = dict(zip(metrics.split(";"), usage.split(";")))
busy = []
lagging = []
for m in want:
    value = (read.get(m) or "0").strip()
    if float(value or 0) == 0:
        print(f"{m}\t{value}")
        continue
    owners_name, owners_count = owners.get(m, (None, None))
    if owners_count:
        print(f"{m}\t{value}\towned by {owners_name}")
        busy.append(m)
    else:
        print(f"{m}\t{value}\tno owning resource is listed ({owners_name}): the consumer is "
              "not identified, which is UNKNOWN -- not absence")
        lagging.append(m)
verdict = "PRESENT" if busy else ("UNKNOWN" if lagging else "ABSENT")
print("VERDICT:" + verdict)
if lagging:
    print("UNIDENTIFIED:" + ";".join(lagging))
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
    UNKNOWN)
      say "    quota: UNKNOWN (non-zero usage no listed resource accounts for -- an"
      say "           unidentified consumer is not absence; read $LOG_DIR/inventory-quota.log)"
      printf 'quota\tUNKNOWN\tabsent\tnon-zero usage with no identified owner\n' \
        >>"$INVENTORY_TSV"
      ;;
    *)
      say "    quota: UNKNOWN (the usage read could not be parsed, which is not zero)"
      printf 'quota\tUNKNOWN\tabsent\tcould not parse the usage read\n' >>"$INVENTORY_TSV"
      ;;
  esac
}

inventory() {
  local mode="$1"
  INVENTORY_TSV="$LOG_DIR/inventory-$mode.tsv"
  : >"$INVENTORY_TSV"
  say "inventory ($mode): provider reads only, no mutation"
  disk_quota_record
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
  probe_service_account service-account-provisioner "$GCP_PROVISIONER_SA"
  provider_probe service-account-loki        absent gcloud iam service-accounts describe "$CLUSTER-loki@$PROJECT.iam.gserviceaccount.com" --project "$PROJECT" --format='value(email)'
  provider_probe service-account-thanos      absent gcloud iam service-accounts describe "$CLUSTER-thanos@$PROJECT.iam.gserviceaccount.com" --project "$PROJECT" --format='value(email)'
  probe_custom_role custom-role "$GCP_ROLE_ID"
  provider_probe role-binding   absent  gcloud projects get-iam-policy "$PROJECT" --flatten='bindings[].members' --filter="bindings.members=serviceAccount:$GCP_PROVISIONER_SA" --format='value(bindings.role)'
  probe_impersonator_binding impersonator-binding "$PROVISIONER_SA_VERDICT" "$GCP_PROVISIONER_SA"
  provider_probe peering        absent  gcloud compute networks peerings list --project "$PROJECT" --filter="name~servicenetworking" --format='value(name)'
  provider_probe state-bucket   present gcloud storage buckets describe "gs://$STATE_BUCKET" --project "$PROJECT" --format='value(name)'
  provider_probe dns-zone       present gcloud dns managed-zones describe "$ZONE_NAME" --project "$PROJECT" --format='value(name,dnsName)'
  quota_usage
}

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

capture_state_object() {
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
  capture_state_object durable  "bootstrap/gcp/default.tfstate"
}

artifact_status() { if [ -s "$1" ]; then printf 'present (%s bytes)\n' "$(wc -c <"$1" | tr -d ' ')"; else printf 'MISSING\n'; fi; }

bundle_phase_note() {
  if root_reached platform; then
    printf 'phases: the platform root was reached; its state is required\n'
  else
    printf 'phases: the platform root was never initialised; its state is not required\n'
  fi
  if root_reached cloud; then
    printf 'phases: the cloud root was reached; its state is required\n'
  else
    printf 'phases: the cloud root was never initialised; its state is not required\n'
  fi
}

bundle_manifest() {
  local m="$LOG_DIR/evidence-manifest.txt" f
  if [ -d "$LOG_DIR/platform-failure" ]; then
    printf 'platform failure evidence: platform-failure/ (%s files)\n' \
      "$(ls "$LOG_DIR/platform-failure" 2>/dev/null | wc -l)"
  fi
  if [ -s "$LOG_DIR/kubeconfig-waiter.tsv" ]; then
    printf 'run kubeconfig waiter: kubeconfig-waiter.tsv (%s polls; every transition and exit)\n' \
      "$(($(wc -l <"$LOG_DIR/kubeconfig-waiter.tsv") - 1))"
  fi
  if [ -s "$RUN_KUBECONFIG" ]; then
    printf 'run credentials: run-kubeconfig.yaml\n'
  else
    printf 'run credentials: NOT ESTABLISHED\n'
  fi
  if [ -s "$LOG_DIR/platform-failure/capture-summary.txt" ]; then
    printf 'platform failure capture: platform-failure/capture-summary.txt\n'
  fi
  if [ -s "$LOG_DIR/api-readiness.tsv" ]; then
    printf 'api readiness: api-readiness.tsv (%s samples across the platform apply)\n' \
      "$(($(wc -l <"$LOG_DIR/api-readiness.tsv") - 1))"
  fi
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
  bundle_phase_note >>"$m"
  say "evidence manifest: $m"
}

root_reached() {
  case "$1" in
    cloud)    grep -qE -- '-chdir=[^ ]*/platform/cloud/[a-z]+/cluster' "$LOG_DIR/cloud-apply.log" 2>/dev/null ;;
    platform) grep -qE -- '-chdir=[^ ]*/platform/cloud/[a-z]+/platform' "$LOG_DIR/cloud-apply.log" 2>/dev/null ;;
  esac
}

verify_bundle() {
  local missing=0 member
  local required=( "inventory-pre.tsv" "evidence-manifest.txt" )
  root_reached cloud && required+=( "state/cloud.tfstate" )
  root_reached platform && required+=( "state/platform.tfstate" )
  [ "$TEARDOWN_ATTEMPTED" = "1" ] && required+=( "inventory-post.tsv" )
  case "$INSTALL_STATE" in
    failed)    required+=( "fnd0010-classification.txt" ) ;;
    succeeded) required+=( "ready-phases.txt" ) ;;
    none) : ;;
  esac
  case "$APP_STATE" in
    failed)    required+=( "app-pods-all.txt" ) ;;
    succeeded) required+=( "app-transaction.txt" "app-deploy.log" "app-pods.txt" ) ;;
    none) : ;;
  esac
  for member in "${required[@]}"; do
    if [ ! -s "$LOG_DIR/$member" ]; then
      say "  ✗ bundle member missing or empty: $member"
      missing=1
    fi
  done
  if [ -z "$(find "$LOG_DIR/sol-runs" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
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
}

finalise_bundle() {
  verify_bundle || true
}

capture_pre_teardown_inventory() {
  say "capturing the pre-teardown provider inventory (attribution evidence)"
  inventory pre
  say "  pre-teardown inventory: $INVENTORY_TSV"
}

destroy() {
  TEARDOWN_ATTEMPTED=1
  local vars
  mapfile -t vars < <(destroy_vars)
  say "teardown: sol cloud destroy $TARGET"
  ( cd "$WORKSPACE" && "$SOL" cloud destroy "$TARGET" --apply "${vars[@]}" ) \
    >"$LOG_DIR/destroy.log" 2>&1 || say "  (destroy exited non-zero; the verification below decides)"
  if verify_absent; then
    say "teardown verified: absent"
    TEARDOWN_OK=1
  else
    say "teardown NOT verified: resources remain — see $LOG_DIR/inventory-*.tsv and inventory-*.log"
    TEARDOWN_OK=0
  fi
  bundle_manifest
  verify_bundle || true
}

cleanup() {
  local rc=$?
  stop_cluster_kubeconfig_waiter
  api_readiness_probe_stop
  if [ "$KEEP" = "1" ]; then
    say "not tearing down: ${KEEP_REASON:-the delegation boundary is deliberate, not a leak}"
    say "logs: $LOG_DIR"
    return "$rc"
  fi
  if [ "$TEARDOWN_ATTEMPTED" = "0" ] \
    && { [ "$CLOUD_APPLIED" = "1" ] || { [ "$rc" != "0" ] && ! plan_only; }; }; then
    destroy || true
  fi
  say "logs: $LOG_DIR"
  if plan_only; then
    remove_target
    return "$rc"
  fi
  if [ "$TEARDOWN_OK" = "1" ]; then
    remove_target
  elif [ "$CLOUD_APPLIED" = "0" ]; then
    remove_target
  else
    say "KEEPING $TARGET_FILE — teardown was not verified, and destroy requires this file."
  fi
  if [ "$TEARDOWN_ATTEMPTED" = "1" ] && [ "$TEARDOWN_OK" != "1" ]; then rc=1; fi
  if [ "$BUNDLE_ATTEMPTED" = "1" ] && [ "$BUNDLE_OK" != "1" ]; then rc=1; fi
  return "$rc"
}
TEARDOWN_OK=0
trap cleanup EXIT

plan_only() { [ "${PLAN_ONLY:-0}" = "1" ]; }

phase_cloud() {
  write_target
  local vars; mapfile -t vars < <(cloud_vars)

  reconcile_durable_root || return 1

  if plan_only; then
    run cloud-plan "$SOL" cloud plan "$TARGET" "${vars[@]}"
    say "PLAN_ONLY=1: nothing created; target and variables validated"
    return 0
  fi

  CLOUD_APPLIED=1
  INSTALL_STATE=succeeded
  start_ns_watcher
  start_cluster_kubeconfig_waiter
  api_readiness_probe_start
  if ! run cloud-apply "$SOL" cloud apply "$TARGET" "${vars[@]}"; then
    INSTALL_STATE=failed
    say "cloud apply failed -- capturing the discriminator before any teardown"
    capture_pre_teardown_inventory
    freeze_evidence
    capture_platform_failure_evidence
    capture_fnd0010
    finalise_bundle
    return 1
  fi

  capture_ready_evidence

  if [ ! -s "$LOG_DIR/nameservers.txt" ] && ! gcloud dns managed-zones describe "$ZONE_NAME" --project "$PROJECT" \
    --format='value(nameServers)' >"$LOG_DIR/nameservers.txt" 2>"$LOG_DIR/nameservers.err"; then
    say "could not read the zone's nameservers — the delegation half cannot proceed"
    capture_pre_teardown_inventory
    freeze_evidence
    finalise_bundle
    return 1
  fi
  say "authoritative nameservers for $BASE_DOMAIN (paste these at Squarespace as NS records named 'qual-gcp'):"
  tr ';' '\n' <"$LOG_DIR/nameservers.txt" | sed 's/^/    /'

  capture_pre_teardown_inventory
  freeze_evidence
  finalise_bundle

  local deadline=$(( $(date +%s) + DELEGATION_WAIT_MINUTES * 60 ))
  say "waiting up to ${DELEGATION_WAIT_MINUTES}m for the delegation to resolve (Ctrl-C to continue later)"
  while [ "$(date +%s)" -lt "$deadline" ]; do
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

cluster_describable() {
  local name
  name="$(gcloud container clusters describe "$CLUSTER" --region "$REGION" --project "$PROJECT" \
      --format='value(name)' 2>/dev/null)" && [ -n "$name" ]
}

kube_capture() {
  local name="$1"; shift
  timeout "${KUBE_CAPTURE_TIMEOUT_S:-30}" "$@" >"$LOG_DIR/$name.log" 2>&1 || true
  say "  captured $name.log ($(wc -l <"$LOG_DIR/$name.log" | tr -d ' ') lines)"
}

api_probe_sample() {
  local out="$1" reported configured verdict detail
  reported="$(gcloud container clusters describe "${CLUSTER:-}" --region "${REGION:-}" \
    --project "${PROJECT:-}" --format='value(endpoint)' 2>/dev/null | tr -d '\r' \
    || printf '')"
  configured="$(kubeconfig_server_for_cluster "${KUBECONFIG:-$HOME/.kube/config}" "${CLUSTER:-}" \
    | tr -d '\r')"
  configured="${configured#https://}"
  configured="${configured#http://}"
  configured="${configured%%/*}"
  configured="${configured%%:*}"
  if detail="$(timeout "${KUBE_CAPTURE_TIMEOUT_S:-30}" kubectl get --raw /readyz --request-timeout=5s 2>&1)"; then
    verdict=REACHABLE
  else
    verdict=UNREACHABLE
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${reported:--}" \
    "${configured:--}" "$verdict" "$(printf '%s' "$detail" | tr '\n' ' ' | cut -c1-120)" \
    >>"$out" 2>/dev/null || true
}

api_probe_sample_or_record() {
  local out="$1"
  if ! api_probe_sample "$out" 2>/dev/null; then
    printf '%s\t-\t-\tPROBE_FAILED\tapi_probe_sample exited non-zero\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$out" 2>/dev/null || true
  fi
}

api_probe_loop() {
  local out="$1" parent=$$
  while :; do
    if ! kill -0 "$parent" 2>/dev/null; then
      exit 0
    fi
    api_probe_sample_or_record "$out"
    sleep "${API_PROBE_INTERVAL_S:-15}"
  done
}

api_readiness_probe_start() {
  local out="$LOG_DIR/api-readiness.tsv"
  if [ "${API_READINESS_PROBE:-1}" != "1" ]; then
    say "api readiness probe: DISABLED by API_READINESS_PROBE"
    return 0
  fi
  if ! : >"$out"; then
    say "api readiness probe: DISABLED (cannot write $out) — the run continues unobserved"
    return 0
  fi
  printf 'timestamp\tserver_reported\tserver_configured\tverdict\tdetail\n' >>"$out" || true
  api_probe_sample_or_record "$out"
  api_probe_loop "$out" &
  API_PROBE_PID=$!
  say "api readiness probe: every ${API_PROBE_INTERVAL_S:-15}s -> $out (pid $API_PROBE_PID)"
}

api_readiness_probe_stop() {
  if [ -n "${API_PROBE_PID:-}" ] && kill -0 "$API_PROBE_PID" 2>/dev/null; then
    kill -TERM "$API_PROBE_PID" 2>/dev/null || true
    wait "$API_PROBE_PID" 2>/dev/null || true
    say "api readiness probe stopped ($(wc -l <"$LOG_DIR/api-readiness.tsv" 2>/dev/null || echo 0) lines)"
  fi
  API_PROBE_PID=""
}

kubeconfig_has_cluster() {
  python3 "$OBSERVER" kubeconfig --file "${1:-}" --cluster "${2:-}" >/dev/null 2>&1
}

cluster_kubeconfig_waiter() {
  local parent=$$ status polls=0
  local journal="$LOG_DIR/kubeconfig-waiter.tsv"
  local deadline
  deadline=$(( $(date +%s) + ${CLUSTER_WAIT_TIMEOUT_S:-1800} ))
  printf 'timestamp\tpoll\tcluster_status\taction\toutcome\n' >"$journal" 2>/dev/null || true
  note() {
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$polls" "$1" "$2" "$3" \
      >>"$journal" 2>/dev/null || true
  }
  while :; do
    polls=$((polls + 1))
    if ! kill -0 "$parent" 2>/dev/null; then
      note "-" "parent-gone" "the run ended before credentials existed"
      exit 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      note "-" "timeout" "no credentials after ${CLUSTER_WAIT_TIMEOUT_S:-1800}s"
      say "run kubeconfig waiter: TIMEOUT after ${CLUSTER_WAIT_TIMEOUT_S:-1800}s ($journal)"
      exit 0
    fi
    if kubeconfig_has_cluster "$RUN_KUBECONFIG" "$CLUSTER"; then
      note "-" "established" "credentials for $CLUSTER exist"
      say "run kubeconfig: ready ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
      exit 0
    fi
    status="$(gcloud container clusters describe "$CLUSTER" --region "$REGION" --project "$PROJECT" \
      --format='value(status)' 2>/dev/null | tr -d '\r' || true)"
    case "$status" in
      RUNNING)
        kubeconfig_for_cluster || true
        if kubeconfig_has_cluster "$RUN_KUBECONFIG" "$CLUSTER"; then
          note "$status" "credentials-established" "context pinned to $CLUSTER"
          say "run kubeconfig: established while the cluster became RUNNING ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
          exit 0
        fi
        note "$status" "generation-incomplete" "will retry"
        ;;
      "")
        note "unreadable" "poll-failed" "no status yet: cluster absent, or the read failed"
        ;;
      *)
        note "$status" "waiting" "cluster not RUNNING yet"
        ;;
    esac
    sleep "${CLUSTER_KUBECONFIG_POLL_S:-10}"
  done
}

start_cluster_kubeconfig_waiter() {
  cluster_kubeconfig_waiter &
  KUBECONFIG_WAITER_PID=$!
  say "run kubeconfig waiter: pid $KUBECONFIG_WAITER_PID, polling every ${CLUSTER_KUBECONFIG_POLL_S:-10}s"
}

stop_cluster_kubeconfig_waiter() {
  if [ -n "${KUBECONFIG_WAITER_PID:-}" ] && kill -0 "$KUBECONFIG_WAITER_PID" 2>/dev/null; then
    kill -TERM "$KUBECONFIG_WAITER_PID" 2>/dev/null || true
    wait "$KUBECONFIG_WAITER_PID" 2>/dev/null || true
    if [ -s "$RUN_KUBECONFIG" ] && kubeconfig_has_cluster "$RUN_KUBECONFIG" "$CLUSTER"; then
      printf '%s\t-\t-\tstopped-by-run\tcredentials existed; the run ended\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$LOG_DIR/kubeconfig-waiter.tsv" 2>/dev/null || true
    else
      printf '%s\t-\t-\tSTOPPED-WITHOUT-CREDENTIALS\tthe run ended before credentials existed\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$LOG_DIR/kubeconfig-waiter.tsv" 2>/dev/null || true
    fi
  fi
  KUBECONFIG_WAITER_PID=""
}

kube_capture_evidence() {
  local dir="$1"
  if ! python3 "$OBSERVER" capture --dir "$dir" --kubeconfig "$RUN_KUBECONFIG" \
      --cluster "$CLUSTER" --bound "${KUBE_CAPTURE_TIMEOUT_S:-30}"; then
    say "  platform-failure evidence: the observer could not run at all — recorded, not interpreted"
    printf 'observer.py could not run: no Kubernetes evidence was collected for this failure.\n' \
      >>"$dir/CAPTURE-UNAVAILABLE.txt" 2>/dev/null || true
  fi
  return 0
}

capture_platform_failure_evidence() {
  local dir="$LOG_DIR/platform-failure"
  if ! mkdir -p "$dir" 2>/dev/null; then
    say "  platform-failure evidence: DISABLED (cannot create $dir) — the run continues unobserved"
    return 0
  fi
  if ! kubeconfig_has_cluster "$RUN_KUBECONFIG" "$CLUSTER"; then
    kubeconfig_for_cluster || true
  fi
  local credentials=yes
  if ! kubeconfig_has_cluster "$RUN_KUBECONFIG" "$CLUSTER"; then
    credentials=no
    say "  platform-failure evidence: NO CREDENTIALS for $CLUSTER — every read is recorded, none is evidence"
  fi
  say "capturing read-only Kubernetes evidence for the platform-apply failure (credentials: $credentials)"
  kube_capture_evidence "$dir"
  say "  platform-failure evidence: $dir ($(ls "$dir" 2>/dev/null | wc -l) files, summary in capture-summary.txt)"
}

kubeconfig_for_cluster() {
  gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" --project "$PROJECT" \
    >"$LOG_DIR/kubeconfig.log" 2>&1 || true
  local context
  context="$(kubectl config get-contexts -o name 2>/dev/null | grep -F -- "$CLUSTER" | head -1 || true)"
  if [ -n "$context" ]; then
    kubectl config use-context "$context" >>"$LOG_DIR/kubeconfig.log" 2>&1 || true
    say "  kubeconfig: using context $context (pinned to this run's cluster)"
  else
    say "  kubeconfig: no context matching $CLUSTER is present — observations may not target it"
  fi
}

kubeconfig_server_for_cluster() {
  python3 "$OBSERVER" server --file "${1:-}" --cluster "${2:-}" 2>/dev/null || printf -- '-\n'
}

capture_fnd0010() {
  capture_provisioner_bindings
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
  kube_capture fnd0010-cainjector-logs kubectl -n cert-manager logs deploy/cert-manager-cainjector --tail=-1
  kube_capture fnd0010-controller-logs kubectl -n cert-manager logs deploy/cert-manager --tail=-1
  kube_capture fnd0010-webhook-logs kubectl -n cert-manager logs deploy/cert-manager-webhook --tail=-1
  kube_capture fnd0010-ca-secret kubectl -n cert-manager get secret cert-manager-webhook-ca \
    -o jsonpath='{.metadata.name} type={.type} created={.metadata.creationTimestamp} keys={.data}'
  kube_capture fnd0010-tls-secret kubectl -n cert-manager get secret cert-manager-webhook-tls \
    -o jsonpath='{.metadata.name} type={.type} created={.metadata.creationTimestamp} keys={.data}'
  kube_capture fnd0010-startupapicheck-pod kubectl -n cert-manager get pods \
    -l job-name=cert-manager-startupapicheck -o yaml
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
    if grep -qiE 'Error: .*already exists|already exists$' \
        "$LOG_DIR/cloud-apply.log" "$LOG_DIR/destroy.log" 2>/dev/null; then
      printf 'TERRAFORM_ALREADY_EXISTS\n'
    elif grep -qiE 'warden-validating|GKE Warden rejected|autogke-' \
        "$LOG_DIR/cloud-apply.log" "$LOG_DIR/destroy.log" "$LOG_DIR/fnd0010-events.log" 2>/dev/null; then
      printf 'ADMISSION_DENIED\n'
    elif grep -qiE 'QUOTA_EXCEEDED|CreateVolume failed|failed to insert .*disk' \
        "$LOG_DIR/fnd0010-events.log" "$LOG_DIR/cloud-apply.log" 2>/dev/null; then
      printf 'PROVIDER_DISK_QUOTA_EXCEEDED\n'
    elif grep -qiE 'managed-namespaces-limitation|leader election record|cannot create resource "leases"' \
        "$LOG_DIR/fnd0010-controller-logs.log" "$LOG_DIR/fnd0010-cainjector-logs.log" 2>/dev/null; then
      printf 'LEADER_ELECTION_DENIED\n'
    elif grep -qiE 'x509|unknown authority|certificate signed by unknown|tls: failed to verify' \
        "$check_log" "$job_log" 2>/dev/null; then
      printf 'TLS_CA_OR_CERTIFICATE\n'
    elif grep -qiE 'no matches for kind|could not find the requested resource|failed to discover|unable to retrieve the complete list of server APIs' \
        "$check_log" "$job_log" 2>/dev/null; then
      printf 'CRD_OR_API_DISCOVERY\n'
    elif grep -qiE 'forbidden|cannot create resource|is not allowed to' "$check_log" "$job_log" 2>/dev/null; then
      printf 'RBAC\n'
    elif grep -qiE 'context deadline exceeded|dial tcp|i/o timeout|connection refused|no route to host' \
        "$check_log" "$job_log" 2>/dev/null; then
      printf 'WEBHOOK_REACHABILITY\n'
    elif grep -qiE 'FailedScheduling|Unschedulable|Insufficient (cpu|memory)|no nodes available' \
        "$events" "$LOG_DIR/fnd0010-pods.log" 2>/dev/null; then
      printf 'SCHEDULING_AMBIENT\n'
    else
      printf 'UNKNOWN\n'
    fi
    printf '\n-- why (matching lines; empty means the signature was not in the captured evidence) --\n'
    grep -hiE 'Error: .*already exists|already exists$|warden-validating|GKE Warden rejected|autogke-|QUOTA_EXCEEDED|CreateVolume failed|managed-namespaces-limitation|leader election record|cannot create resource "leases"|x509|unknown authority|certificate signed by unknown|tls: failed to verify|no matches for kind|could not find the requested resource|failed to discover|forbidden|cannot create resource|context deadline exceeded|dial tcp|i/o timeout|connection refused|no route to host|FailedScheduling|Unschedulable|Insufficient (cpu|memory)' \
      "$check_log" "$job_log" "$events" "$LOG_DIR/fnd0010-pods.log" \
      "$LOG_DIR/cloud-apply.log" "$LOG_DIR/destroy.log" \
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

capture_provisioner_bindings() {
  kube_capture bindings-provisioner-cluster kubectl get clusterrolebinding \
    sol-platform-provisioner-cluster -o json
  kube_capture bindings-provisioner-rolebindings kubectl get rolebinding -A \
    --field-selector metadata.name=sol-platform-provisioner -o json
  kube_capture bindings-provisioner-subjects kubectl get clusterrolebinding,rolebinding -A \
    -o custom-columns=KIND:.kind,NS:.metadata.namespace,NAME:.metadata.name,SUBJECTS:.subjects[*].name
}

capture_ready_evidence() {
  say "capturing Ready-path evidence (the platform install returned success)"
  capture_provisioner_bindings
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
  write_target
  CLOUD_APPLIED=1
  capture_pre_teardown_inventory
  freeze_evidence
  finalise_bundle
  destroy
}

app_registry() { printf '%s-docker.pkg.dev/%s/%s' "$REGION" "$PROJECT" "$CLUSTER"; }

app_kube_context() { printf 'gke_%s_%s_%s' "$PROJECT" "$REGION" "$CLUSTER"; }

app_services() { printf '%s\n' charge_svc notify_worker; }

app_helpers() {
  printf '%s\n' say app_registry app_kube_context app_services app_k8s_name app_context_path \
    app_image_ref build_app_images push_app_images app_ingress_summary app_load_balancer_address \
    app_transaction
}

app_postgres_url() {
  local state="$LOG_DIR/state/cloud.tfstate.json"
  [ -s "$state" ] || state="$LOG_DIR/state/cloud.tfstate"
  [ -s "$state" ] || return 1
  jq -r '.outputs.postgres_url.value // empty' "$state" 2>/dev/null
}

app_redact_url() { printf '%s' "$1" | sed 's#://[^@]*@#://***@#'; }

app_load_runtime_secrets() {
  capture_state_object cloud "sol/$TARGET/cloud.tfstate/default.tfstate"
  local url
  if ! url="$(app_postgres_url)" || [ -z "$url" ]; then
    say "could not read the cluster root's postgres_url output, so POSTGRES_URL cannot be established"
    return 1
  fi
  export POSTGRES_URL="$url"
  export SOL_API_KEY="${SOL_API_KEY:-$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)}"
  {
    printf 'POSTGRES_URL: %s\n' "$(app_redact_url "$url")"
    printf 'SOL_API_KEY: %s (redacted; generated for this run, the value the operator would \
      place in their secret store)\n' "$(printf '%s' "$SOL_API_KEY" | cut -c1-2)***"
  } >"$LOG_DIR/app-runtime-secrets.txt" 2>&1
  say "the workspace's declared runtime secrets are established from the platform's own output"
  say "  (POSTGRES_URL) and generated for this run (SOL_API_KEY): $LOG_DIR/app-runtime-secrets.txt"
}

app_k8s_name() { printf '%s' "$1" | tr '_' '-'; }

app_context_path() {
  case "$1" in
    charge_svc) printf 'app/payments/charge_svc' ;;
    notify_worker) printf 'app/comms/notify_worker' ;;
    *) return 1 ;;
  esac
}

app_image_ref() { printf '%s/pluto/%s:%s' "$(app_registry)" "$(app_k8s_name "$1")" "$APP_TAG"; }

write_app_target() {
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
      letsencrypt_email: $LE_EMAIL
      cluster_issuer: $CLUSTER_ISSUER
      terraform_var_file: $TFVARS

      state_bucket: $STATE_BUCKET

      gcp:
        project_id: $PROJECT
        provisioner_impersonator: $IMPERSONATOR

      kube_context: $(app_kube_context)

      destroy_retention: none

      resources:
        app_db:
          size: small
        events: {}

      services:
        charge_svc: {}
        notify_worker: {}
        checkout_svc:
          omit: true
        order_svc:
          omit: true
        fulfillment_worker:
          omit: true
YAML
  say "wrote the app target $TARGET ($TARGET_FILE)"
  say "  no profile is selected: this row qualifies the application path, and the profile's"
  say "  guarantees are not claimed by it (the production profile refuses gcp today)"
  say "  charge_svc and notify_worker are the pair whose transaction this row exercises;"
  say "  checkout_svc (ingress_host outside any zone Sol can issue for) and the two TypeScript"
  say "  services are omitted, so the omitted ones are not silently deployed and unverified"
}

build_app_images() {
  local service path ref
  for service in $(app_services); do
    path="$(app_context_path "$service")" || return 1
    ref="$(app_image_ref "$service")"
    say "  docker build $ref (context: the workspace root)"
    docker build -f "$path/Dockerfile" -t "$ref" . || return 1
  done
}

push_app_images() {
  gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet || return 1
  local service
  for service in $(app_services); do
    say "  docker push $(app_image_ref "$service")"
    docker push "$(app_image_ref "$service")" || return 1
  done
}

app_ingress_summary() {
  kubectl get ingress --all-namespaces -o wide >"$LOG_DIR/app-ingresses.txt" 2>&1 || true
  kubectl get certificates --all-namespaces >"$LOG_DIR/app-certificates.txt" 2>&1 || true
}

app_load_balancer_address() {
  kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
}

app_transaction() {
  local ns=pluto-payments port=18080
  kubectl -n "$ns" get pods -o wide >"$LOG_DIR/app-pods.txt" 2>&1 || return 1
  kubectl -n "$ns" get events --sort-by=.lastTimestamp >"$LOG_DIR/app-events.txt" 2>&1 || true
  kubectl -n "$ns" logs -l app.kubernetes.io/component=svc --tail=80 --all-containers=true \
    >"$LOG_DIR/app-charge-svc.log" 2>&1 || true
  kubectl -n "$ns" logs -l app.kubernetes.io/component=worker --tail=80 --all-containers=true \
    >"$LOG_DIR/app-notify-worker.log" 2>&1 || true
  kubectl -n "$ns" port-forward "svc/$(app_k8s_name charge_svc)" "$port:80" \
    >"$LOG_DIR/app-port-forward.log" 2>&1 &
  local forwarder=$!
  local attempt=0
  until curl -fsS -m 5 "localhost:$port/health" >"$LOG_DIR/app-health.txt" 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 12 ]; then
      say "  the service never answered /health over the port-forward"
      kill "$forwarder" 2>/dev/null || true
      return 1
    fi
    sleep 5
  done
  {
    printf 'health: %s\n' "$(cat "$LOG_DIR/app-health.txt")"
    printf 'charge: '
    curl -fsS -m 30 -X POST "localhost:$port/charges" \
      -H 'Content-Type: application/json' \
      -d '{"customer_id":"cus_qualification","amount_cents":4999,"currency":"usd"}' \
      >"$LOG_DIR/app-charge.txt" 2>&1 && cat "$LOG_DIR/app-charge.txt" || printf 'FAILED\n'
    printf '\n'
  } >"$LOG_DIR/app-transaction.txt" 2>&1
  local charge_id
  charge_id="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$LOG_DIR/app-charge.txt" 2>/dev/null | head -1)"
  attempt=0
  until [ -n "$charge_id" ] && grep -qF "$charge_id" "$LOG_DIR/app-notifications.txt" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 12 ]; then
      say "  the worker never wrote the charge back within 60s: $charge_id absent from /notifications"
      curl -sS -m 20 "localhost:$port/notifications" >"$LOG_DIR/app-notifications.txt" 2>&1 || true
      printf 'notifications: %s\n' "$(cat "$LOG_DIR/app-notifications.txt" 2>/dev/null)" \
        >>"$LOG_DIR/app-transaction.txt"
      kill "$forwarder" 2>/dev/null || true
      return 1
    fi
    sleep 5
    curl -fsS -m 20 "localhost:$port/notifications" >"$LOG_DIR/app-notifications.txt" 2>&1 || true
  done
  {
    printf 'notifications: %s\n' "$(cat "$LOG_DIR/app-notifications.txt")"
    printf 'the worker consumed the charge and wrote it back: %s\n' "$charge_id"
  } >>"$LOG_DIR/app-transaction.txt" 2>&1
  kill "$forwarder" 2>/dev/null || true
  wait "$forwarder" 2>/dev/null || true
  app_ingress_summary
  app_load_balancer_address >"$LOG_DIR/app-load-balancer.txt" 2>&1 || true
  return 0
}

capture_app_evidence() {
  kubectl get pods --all-namespaces >"$LOG_DIR/app-pods-all.txt" 2>&1 || true
  kubectl get events --all-namespaces --sort-by=.lastTimestamp >"$LOG_DIR/app-events-all.txt" 2>&1 || true
  app_ingress_summary
  app_load_balancer_address >"$LOG_DIR/app-load-balancer.txt" 2>&1 || true
}

phase_app() {
  KEEP=1
  KEEP_REASON="the application row keeps its specimen: capture happens either way, and destroy is a deliberate separate phase"
  APP_STATE=failed
  if [ ! -s "$RUN_KUBECONFIG" ]; then
    say "app: no run kubeconfig in $LOG_DIR — run the cloud phase first, which establishes it"
    exit 2
  fi
  write_app_target
  if ! run app-build bash -c "$(declare -f $(app_helpers)); build_app_images"; then
    capture_app_evidence
    freeze_evidence
    finalise_bundle
    return 1
  fi
  if ! run app-push bash -c "$(declare -f $(app_helpers)); push_app_images"; then
    capture_app_evidence
    freeze_evidence
    finalise_bundle
    return 1
  fi
  if ! app_load_runtime_secrets; then
    capture_app_evidence
    freeze_evidence
    finalise_bundle
    return 1
  fi
  if ! run migrate-apply "$SOL" migrate apply "$TARGET" --registry "$(app_registry)"; then
    capture_app_evidence
    freeze_evidence
    finalise_bundle
    return 1
  fi
  if ! run app-deploy "$SOL" deploy "$TARGET" --registry "$(app_registry)" --image-tag "$APP_TAG"; then
    capture_app_evidence
    freeze_evidence
    finalise_bundle
    return 1
  fi
  if ! run app-transaction bash -c "$(declare -f $(app_helpers)); app_transaction"; then
    capture_app_evidence
    freeze_evidence
    finalise_bundle
    return 1
  fi
  APP_STATE=succeeded
  say "the application transaction completed: a charge was accepted, the worker consumed it, and"
  say "the service read the worker's row back out of PostgreSQL"
  finalise_bundle
}

usage() {
  cat <<'USAGE'
live-qual.sh — one GCP qualification specimen, and the evidence it produces

usage: live-qual.sh PHASE

phases
  cloud     reconcile the durable root, start the run-kubeconfig waiter and the
            API-readiness probe, run `sol cloud apply`, and on failure capture the
            Kubernetes evidence, the cert-manager discriminator and the provider
            inventory before any teardown. On success it continues to the delegation
            hand-off and keeps the substrate for the TLS rows.
  app       build and push this row's two images into the target's Artifact Registry, apply the
            workspace's migrations, run `sol deploy`, and verify the application transaction
            (a charge accepted, the worker consuming it, and the service reading the worker's
            row back out of PostgreSQL) with the pods, events and logs captured either way.
            Migrations, like the deploy, run against the target's registry: `sol migrate
            apply` submits an in-cluster Job built from an image there, so it is given the
            same --registry the deploy is. The workspace's declared runtime secrets
            (POSTGRES_URL, SOL_API_KEY) come from the operator's side of the contract -- the
            cluster root's postgres_url output plus a value for the API key -- and the
            bundle records them redacted, never in the clear.
            The target it writes selects no profile: this row qualifies the application path,
            and claims nothing the production profile's guarantees would promise.
  destroy   freeze and destroy an existing target, then verify absence
  stop      stop the run recorded in LOG_DIR (by its own process group), then destroy
  verify    read-only absence check; invokes no teardown

required
  CLUSTER        this run's cluster name (also the name every provider probe filters on)
  IMPERSONATOR   user:<email> the provisioner is impersonated as
  LE_EMAIL       ACME contact address, for the platform's certificates

optional (defaults shown)
  TARGET=qual/gcp/us-central1
  PROJECT=sol-qualification   REGION=us-central1
  BASE_DOMAIN=qual-gcp.sol-fab.dev
  PHASE_TIMEOUT=1200          a full GCP attempt needs >= 1800; the runbook uses 2700
  SOL=_build/default/cli/bin/main.exe
  WORKSPACE=examples/pluto    TFVARS=internal/qualification/gcp/qual-gcp.tfvars
  LOG_DIR=/tmp/sol-gcp-qual-<timestamp>   XDG_DATA_HOME

The bundle is LOG_DIR: the harness's own narrative (harness.log), phase transcripts,
the run kubeconfig and the waiter journal, the API-readiness samples, the failure
capture and its summary, the provider inventory, the Terraform state snapshots, and
evidence-manifest.txt.
USAGE
}

case "${1:-}" in
  cloud)    phase_cloud ;;
  app)      phase_app ;;
  platform)
    say "no platform phase: 'sol cloud apply' installs the platform, and this harness captures"
    say "its discriminator in the cloud phase. Run: live-qual.sh cloud"
    exit 2
    ;;
  stop)
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
    KEEP=1
    KEEP_REASON="verify does not mutate; nothing to tear down"
    if verify_absent; then say "verify: absent"; else say "verify: resources remain"; exit 1; fi
    ;;
  *)
    KEEP=1
    KEEP_REASON="no phase was named, so nothing was attempted and nothing is torn down"
    usage
    exit 2
    ;;
esac
