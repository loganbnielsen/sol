#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
sol="$(realpath "${1:-$root/_build/default/cli/sol/bin/main.exe}")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/work/sol/prod/aws" "$tmp/markers"

cat >"$tmp/work/sol.yml" <<'EOF'
project: lifecycle-test
EOF
cat >"$tmp/work/sol/prod/aws/us-east-1.yml" <<'EOF'
target:
  base_domain: example.test
  cluster_name: lifecycle-test
  letsencrypt_email: ops@example.test
  state_bucket: lifecycle-state
  state_lock_table: lifecycle-lock
  provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
EOF

cat >"$tmp/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'terraform %s\n' "$*" >>"$LIFECYCLE_LOG"
fail_once() {
  [ "${FAIL_ON:-}" = "$1" ] || return 1
  marker="$FAIL_MARKER_DIR/$1"
  [ ! -e "$marker" ] || return 1
  : >"$marker"
  return 0
}
case "$*" in
  *" init "*|*" init")
    case "$*" in *-backend-config=*) : ;; *) exit 91 ;; esac
    case "$*" in *infra/base*) if fail_once platform-init; then exit 20; fi ;; esac
    ;;
  *" output -json"*)
    if [ "${OUTPUT_ABSENT:-}" = 1 ]; then printf '{}\n'; exit 0; fi
    if fail_once outputs; then exit 20; fi
    cat <<'JSON'
{"cluster_name":{"value":"lifecycle-test"},"provisioner_role_arn":{"value":"arn:aws:iam::111122223333:role/sol-provisioner"},"cert_manager_irsa_arn":{"value":"arn:aws:iam::111122223333:role/cert-manager"},"loki_s3_bucket":{"value":"loki"},"loki_irsa_arn":{"value":"loki-role"},"thanos_s3_bucket":{"value":"thanos"},"thanos_irsa_arn":{"value":"thanos-role"},"grafana_irsa_arn":{"value":null},"managed_resource_dashboards":{"value":{}}}
JSON
    ;;
  *" plan "*)
    if fail_once plan; then exit 20; fi
    ;;
  *infra/aws*" apply "*"provisioner_bootstrap_admin=true"*)
    if fail_once cloud; then exit 20; fi
    ;;
  *infra/aws*" apply "*"provisioner_bootstrap_admin=false"*)
    if fail_once deescalate; then exit 20; fi
    ;;
  *infra/base*" apply "*"-target="*)
    if fail_once prerequisites; then exit 20; fi
    ;;
  *infra/base*" apply "*)
    if fail_once platform; then exit 20; fi
    ;;
esac
EOF

cat >"$tmp/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'aws %s\n' "$*" >>"$LIFECYCLE_LOG"
if [ "$1 $2" = "eks describe-cluster" ] || [ "$1 $2" = "eks describe-addon" ]; then
  if [ "${FAIL_ON:-}" = cloud-verify ] && [ ! -e "$FAIL_MARKER_DIR/cloud-verify" ]; then
    : >"$FAIL_MARKER_DIR/cloud-verify"; exit 20
  fi
  printf 'ACTIVE\n'; exit 0
fi
[ "$1 $2" = "eks update-kubeconfig" ] || exit 90
case " $* " in *" --role-arn arn:aws:iam::111122223333:role/sol-provisioner "*) : ;; *) exit 91 ;; esac
while [ "$#" -gt 0 ]; do
  if [ "$1" = --kubeconfig ]; then shift; path="$1"; break; fi
  shift
done
[ -n "${path:-}" ] && [ "$KUBECONFIG" = "$path" ] || exit 92
printf '%s\n' "$path" >>"$KUBECONFIG_LOG"
if [ "${FAIL_ON:-}" = access ] && [ ! -e "$FAIL_MARKER_DIR/access" ]; then
  : >"$FAIL_MARKER_DIR/access"; exit 20
fi
: >"$path"
EOF

cat >"$tmp/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'kubectl %s\n' "$*" >>"$LIFECYCLE_LOG"
[ "$KUBECONFIG" != /ambient/forbidden ] || exit 93
# Plan-only fault knobs: an intermediate target whose provisioner RBAC is not
# yet established, one whose cert-manager CRDs are not yet Established, and one
# where the provisioner cannot authenticate to the cluster at all.
if [ "${AUTH_ABSENT:-}" = 1 ]; then
  case "$*" in "auth can-i "*) exit 94 ;; esac
fi
if [ "${RBAC_ABSENT:-}" = 1 ]; then
  case "$*" in
    # Authentication succeeds (empty rule set); only the RBAC checks are denied.
    "auth can-i --list") : ;;
    "auth can-i "*) exit 1 ;;
  esac
fi
if [ "${CRDS_ABSENT:-}" = 1 ]; then
  case "$*" in *"--for=condition=Established"*) exit 1 ;; esac
fi
if [ "${FAIL_ON:-}" = crds ] && [ ! -e "$FAIL_MARKER_DIR/crds" ] &&
   case "$*" in *"--timeout=180s"*) true;; *) false;; esac; then
  : >"$FAIL_MARKER_DIR/crds"; exit 20
fi
if [ "${FAIL_ON:-}" = rbac ] && [ ! -e "$FAIL_MARKER_DIR/rbac" ] &&
   case "$*" in "auth can-i create namespaces") true;; *) false;; esac; then
  : >"$FAIL_MARKER_DIR/rbac"; exit 20
fi
case "$*" in
  "auth can-i "*" -n default") exit 1 ;;
  "auth can-i bind "*|"auth can-i escalate "*) exit 1 ;;
  *"storageclass/gp3"*) printf 'ebs.csi.aws.com true' ;;
  *"service/ingress-nginx-controller"*) printf 'lb.example.test' ;;
esac
if [ "${FAIL_ON:-}" = readiness ] && [ ! -e "$FAIL_MARKER_DIR/readiness" ] &&
   case "$*" in *"csidriver/ebs.csi.aws.com"*) true;; *) false;; esac; then
  : >"$FAIL_MARKER_DIR/readiness"; exit 20
fi
EOF
chmod +x "$tmp/bin/terraform" "$tmp/bin/aws" "$tmp/bin/kubectl"

export PATH="$tmp/bin:$PATH"
export SOL_HOME="$root"
export TF_VAR_db_password=offline-only
export KUBECONFIG=/ambient/forbidden
export FAIL_MARKER_DIR="$tmp/markers"
export KUBECONFIG_LOG="$tmp/kubeconfigs"

run_apply() {
  (cd "$tmp/work" && LIFECYCLE_LOG="$1" "$sol" cloud apply prod/aws/us-east-1) >"$1.out" 2>&1
}

for phase in cloud outputs cloud-verify access platform-init prerequisites crds deescalate rbac platform readiness; do
  rm -f "$tmp/markers/$phase"
  log="$tmp/$phase.log"
  if (export FAIL_ON="$phase"; run_apply "$log"); then
    echo "cloud apply unexpectedly survived injected $phase failure" >&2
    exit 1
  fi
  if ! (export FAIL_ON=""; run_apply "$log"); then
    cat "$log" >&2
    cat "$log.out" >&2
    echo "cloud apply did not resume after injected $phase failure" >&2
    exit 1
  fi
done

log="$tmp/success.log"
(export FAIL_ON=""; run_apply "$log")
grep -F 'key=sol/prod/aws/us-east-1/cloud.tfstate' "$log" >/dev/null
grep -F 'key=sol/prod/aws/us-east-1/platform.tfstate' "$log" >/dev/null
grep -F -- '-target=helm_release.cert_manager' "$log" >/dev/null
grep -F 'terraform ' "$log" | grep 'infra/base.* apply ' | grep -v -- '-target=' >/dev/null
while IFS= read -r kubeconfig; do test ! -e "$kubeconfig"; done <"$tmp/kubeconfigs"

plan() {
  local log="$1"
  shift
  (cd "$tmp/work" && env LIFECYCLE_LOG="$log" "$@" "$sol" cloud plan prod/aws/us-east-1) \
    >"$log.out" 2>&1
}

# A plan may read state and the cluster, but it must never mutate anything to
# make a later phase plannable.
no_plan_mutation() {
  local log="$1"
  if grep -Eq 'terraform .*( apply | destroy )|kubectl (apply|delete|create|patch|replace|scale|annotate|label|set )|aws .*( create-| delete-| modify-| put-| terminate-| run-)' "$log"; then
    echo "cloud plan mutated or attempted a mutation:" >&2
    cat "$log" >&2
    exit 1
  fi
}

# Absent target: both platform phases Deferred, exit zero, nothing mutated.
log="$tmp/plan-absent.log"
if ! plan "$log" OUTPUT_ABSENT=1; then
  cat "$log.out" >&2
  echo "cloud plan on an absent target must exit zero with Deferred phases" >&2
  exit 1
fi
grep -F 'requires cloud substrate to exist' "$log.out" >/dev/null
no_plan_mutation "$log"

# Cluster exists but the provisioner's platform RBAC is not yet established:
# both platform phases Deferred because granting bootstrap access would mutate.
log="$tmp/plan-rbac.log"
if ! plan "$log" RBAC_ABSENT=1; then
  cat "$log.out" >&2
  echo "cloud plan before provisioner RBAC must exit zero with Deferred phases" >&2
  exit 1
fi
grep -F 'requires provisioner platform RBAC established by an earlier apply' "$log.out" >/dev/null
if grep -F 'terraform ' "$log" | grep 'infra/base.* plan ' >/dev/null; then
  echo "cloud plan planned the platform before its provisioner RBAC existed" >&2
  exit 1
fi
no_plan_mutation "$log"

# The provisioner cannot authenticate to the cluster at all: unavailable
# authentication is non-zero, not a Deferred phase (same exit-1 from can-i).
log="$tmp/plan-auth.log"
if plan "$log" AUTH_ABSENT=1; then
  cat "$log.out" >&2
  echo "cloud plan must exit non-zero when the provisioner cannot authenticate" >&2
  exit 1
fi
grep -F 'could not authenticate to the cluster as the platform provisioner' "$log.out" >/dev/null
no_plan_mutation "$log"

# Cluster and RBAC established, CRDs not yet: prerequisites are plannable and
# the CRD-dependent substrate stays Deferred.
log="$tmp/plan-prereq.log"
if ! plan "$log" CRDS_ABSENT=1; then
  cat "$log.out" >&2
  echo "cloud plan with CRDs not established must exit zero with a Deferred substrate" >&2
  exit 1
fi
grep -F 'requires cert-manager CRDs to be Established' "$log.out" >/dev/null
grep -F -- '-target=helm_release.cert_manager' "$log" >/dev/null
if grep -F 'terraform ' "$log" | grep 'infra/base.* plan ' | grep -v -- '-target=' >/dev/null; then
  echo "cloud plan previewed CRD-dependent platform before its CRDs were Established" >&2
  exit 1
fi
no_plan_mutation "$log"

# Fully established: both phases planned, nothing Deferred.
log="$tmp/plan-full.log"
if ! plan "$log"; then
  cat "$log.out" >&2
  echo "cloud plan on an established target must exit zero" >&2
  exit 1
fi
grep -F -- '-target=helm_release.cert_manager' "$log" >/dev/null
grep -F 'terraform ' "$log" | grep 'infra/base.* plan ' | grep -v -- '-target=' >/dev/null
if grep -F 'DEFERRED' "$log.out" >/dev/null; then
  echo "cloud plan deferred a phase on a fully established target" >&2
  exit 1
fi
no_plan_mutation "$log"

# A plannable-phase failure is non-zero, not silently Deferred.
log="$tmp/plan-fail.log"
rm -f "$tmp/markers/plan"
if plan "$log" FAIL_ON=plan; then
  cat "$log.out" >&2
  echo "cloud plan must exit non-zero when a plannable phase fails" >&2
  exit 1
fi

# Every ephemeral kubeconfig, including the plan runs', is removed.
while IFS= read -r kubeconfig; do test ! -e "$kubeconfig"; done <"$tmp/kubeconfigs"

# An unqualified provider fails closed instead of running the former
# cloud-only path that stopped short of a ready target.
gcp_log="$tmp/gcp.log"
if (cd "$tmp/work" && LIFECYCLE_LOG="$gcp_log" "$sol" cloud plan prod/gcp/us-central1) \
  >"$gcp_log.out" 2>&1
then
  echo "cloud plan accepted the unqualified GCP lifecycle" >&2
  exit 1
fi
grep -F 'qualified only for AWS' "$gcp_log.out" >/dev/null
