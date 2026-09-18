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
  # ADR 0003: a production-profile target makes terraform_vars inject the
  # Ready/Production invariant rds_deletion_protection=true, which is exactly
  # the policy the Destroy policy must override after PrepareDestroy (finding 15).
  profile: production-single-region
  base_domain: example.test
  cluster_name: lifecycle-test
  letsencrypt_email: ops@example.test
  cluster_endpoint_cidr: 203.0.113.0/24
  state_bucket: lifecycle-state
  state_lock_table: lifecycle-lock
  provisioner_role_arn: arn:aws:iam::111122223333:role/sol-provisioner
  # HARDEN-002 run 3, finding 11: must reach the provider root's terraform argv
  # so the module creates the deploy EKS access entry (INFRA-025).
  deploy_role_arn: arn:aws:iam::111122223333:role/sol-deploy
  operator_role_arn: arn:aws:iam::111122223333:role/sol-operator

# ADR 0003: a postgres resource plus the production profile is what makes
# terraform_vars force the Ready/Production invariant rds_deletion_protection=true.
resources:
  app_db:
    type: postgres
    size: small
EOF

cat >"$tmp/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'terraform %s\n' "$*" >>"$LIFECYCLE_LOG"
# HARDEN-002 run 4, finding 12: record the kubeconfig env the platform Terraform
# actually receives. The base providers read KUBE_CONFIG_PATH/KUBE_CONFIG_PATHS
# (not KUBECONFIG), so the assertion below fails if that stops being exported.
[ -n "${KUBE_CONFIG_PATH:-}" ] && printf 'env KUBE_CONFIG_PATH=%s\n' "$KUBE_CONFIG_PATH" >>"$LIFECYCLE_LOG"
[ -n "${KUBE_CONFIG_PATHS:-}" ] && printf 'env KUBE_CONFIG_PATHS=%s\n' "$KUBE_CONFIG_PATHS" >>"$LIFECYCLE_LOG"
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
    # HARDEN-002 run 3, finding 10: terraform 1.9.8 OMITS an output whose value
    # is null, so a real default target (durable observability disabled) has no
    # loki_*/thanos_* keys at all. The fixture must match that, or the harness
    # cannot reproduce the live `Can't get member 'value' of non-object type
    # null` crash this scenario exists to guard.
    cat <<'JSON'
{"cluster_name":{"value":"lifecycle-test"},"provisioner_role_arn":{"value":"arn:aws:iam::111122223333:role/sol-provisioner"},"cert_manager_irsa_arn":{"value":"arn:aws:iam::111122223333:role/cert-manager"},"grafana_irsa_arn":{"value":null},"managed_resource_dashboards":{"value":{}}}
JSON
    ;;
  *" plan "*)
    if fail_once plan; then exit 20; fi
    ;;
  *" show -json")
    if [ "${RDS_ABSENT:-}" = 1 ]; then
      printf '{"values":{"root_module":{"resources":[]}}}\n'
    elif [ -e "$RDS_PREPARED_FILE" ]; then
      printf \
        '{"values":{"root_module":{"resources":[{"type":"aws_db_instance","values":{"deletion_protection":false,"final_snapshot_identifier":"%s"}}]}}}\n' \
        "$(cat "$RDS_PREPARED_FILE")"
    else
      printf \
        '{"values":{"root_module":{"resources":[{"type":"aws_db_instance","values":{"deletion_protection":true,"final_snapshot_identifier":null}}]}}}\n'
    fi
    ;;
  *infra/aws*" apply "*"-target=aws_db_instance.postgres"*)
    if fail_once rds-prepare; then exit 20; fi
    for arg in "$@"; do
      case "$arg" in
        -var=rds_final_snapshot_identifier=*)
          printf '%s' "${arg#-var=rds_final_snapshot_identifier=}" >"$RDS_PREPARED_FILE"
          ;;
      esac
    done
    ;;
  *infra/aws*" apply "*"provisioner_bootstrap_admin=true"*)
    if fail_once cloud; then exit 20; fi
    ;;
  *infra/aws*" apply "*"provisioner_bootstrap_admin=false"*)
    if fail_once deescalate; then exit 20; fi
    ;;
  *infra/base*" apply "*"-target="*)
    if fail_once prerequisites; then exit 20; fi
    # FRESH_TARGET modelling: this apply is what installs cert-manager, and so
    # what brings the CRDs the pre-install freshness probe looks for into
    # existence.
    [ -n "${PLATFORM_INSTALLED_FILE:-}" ] && : >"$PLATFORM_INSTALLED_FILE"
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
# Destroy-path verification wants the opposite of apply's: every resource
# reports absent. Apply and destroy never run in the same process, so one
# env toggle (set only around destroy invocations below) is enough to flip
# the whole mock rather than keying every case on both directions.
if [ "${DESTROYING:-}" = 1 ]; then
  case "$1 $2" in
    "eks describe-cluster"|"eks describe-addon")
      echo "An error occurred (ResourceNotFoundException) when calling the operation" >&2
      exit 254
      ;;
    "rds describe-db-instances")
      echo "An error occurred (DBInstanceNotFound) when calling the operation" >&2
      exit 254
      ;;
    "ecr describe-repositories") printf '\n'; exit 0 ;;
    "resourcegroupstaggingapi get-resources") printf '\n'; exit 0 ;;
    # Anything else (notably "eks update-kubeconfig", still needed to build
    # the platform-phase ephemeral kubeconfig during teardown) falls through
    # to the ordinary logic below.
  esac
fi
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
# Destroy verifies platform absence by checking every platform namespace is
# gone; apply never checks this, so DESTROYING is an unambiguous toggle here.
if [ "${DESTROYING:-}" = 1 ]; then
  case "$*" in "get namespace "*) exit 1 ;; esac
fi
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
# FRESH_TARGET models a target that has not been installed yet: the cert-manager
# CRDs do not exist until this run's own prerequisites apply creates them, which
# is what makes the run enter PlatformInstalling rather than PlatformUpdating.
# Gated on the toggle so every other scenario keeps its original cluster.
if [ "${FRESH_TARGET:-}" = 1 ] && [ ! -e "${PLATFORM_INSTALLED_FILE:-/nonexistent}" ]; then
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
export RDS_PREPARED_FILE="$tmp/markers/rds-prepared"
export PLATFORM_INSTALLED_FILE="$tmp/markers/platform-installed"

run_apply() {
  (cd "$tmp/work" && LIFECYCLE_LOG="$1" "$sol" cloud apply prod/aws/us-east-1) >"$1.out" 2>&1
}

run_destroy() {
  (cd "$tmp/work" && DESTROYING=1 LIFECYCLE_LOG="$1" "$sol" cloud destroy prod/aws/us-east-1 --apply) \
    >"$1.out" 2>&1
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
# HARDEN-002 run 3, finding 11: the target's deploy_role_arn must be routed to
# the provider root (the AWS root declares it and uses it to create the deploy
# EKS access entry INFRA-025 added).
grep -F -- '-var=deploy_role_arn=arn:aws:iam::111122223333:role/sol-deploy' "$log" >/dev/null
# HARDEN-002 run 4, finding 12: the platform Terraform must be handed the
# ephemeral provisioner kubeconfig under the names the providers actually read.
grep -F 'env KUBE_CONFIG_PATH=' "$log" >/dev/null
grep -F 'env KUBE_CONFIG_PATHS=' "$log" >/dev/null
# ADR 0003 (findings 13/14): installing the platform is privileged platform
# establishment, so the full platform apply (the non-targeted base apply) must
# run while the temporary PlatformInstalling authority is still open -- i.e.
# before provisioner-bootstrap-access-remove -- and only then is it revoked.
full_apply_line="$(grep -nF 'terraform ' "$log" | grep 'infra/base.* apply ' | grep -v -- '-target=' | head -1 | cut -d: -f1 || true)"
deescalate_line="$(grep -nF -- 'provisioner_bootstrap_admin=false' "$log" | head -1 | cut -d: -f1 || true)"
if [ -z "$full_apply_line" ] || [ -z "$deescalate_line" ] || [ "$full_apply_line" -ge "$deescalate_line" ]; then
  echo "the platform install must complete before provisioner de-escalation" >&2
  exit 1
fi
while IFS= read -r kubeconfig; do test ! -e "$kubeconfig"; done <"$tmp/kubeconfigs"

# ADR 0003 invariants 3 and 5: the phase a run enters is recomputed from
# observation, and a run may only leave it along an edge the transition relation
# admits. A first install enters PlatformInstalling; a re-apply of an
# already-installed target is the explicit privileged re-entry PlatformUpdating,
# never a silent return to PlatformInstalling -- which the relation rejects, so
# classifying it that way would have made the model and the operation disagree.
fresh_log="$tmp/phase-fresh.log"
rm -f "$PLATFORM_INSTALLED_FILE"
if ! (export FAIL_ON=""; export FRESH_TARGET=1; run_apply "$fresh_log"); then
  cat "$fresh_log" >&2
  cat "$fresh_log.out" >&2
  echo "cloud apply did not complete a first install" >&2
  exit 1
fi
grep -F 'lifecycle phase: PlatformInstalling' "$fresh_log.out" >/dev/null || {
  echo "a first install did not report PlatformInstalling:" >&2
  cat "$fresh_log.out" >&2
  exit 1
}

update_log="$tmp/phase-update.log"
if ! (export FAIL_ON=""; export FRESH_TARGET=1; run_apply "$update_log"); then
  cat "$update_log" >&2
  cat "$update_log.out" >&2
  echo "cloud apply did not complete a re-apply" >&2
  exit 1
fi
grep -F 'lifecycle phase: PlatformUpdating' "$update_log.out" >/dev/null || {
  echo "a re-apply of an installed target did not report PlatformUpdating:" >&2
  cat "$update_log.out" >&2
  exit 1
}
grep -F 'lifecycle phase: PlatformInstalling' "$update_log.out" >/dev/null && {
  echo "a re-apply of an installed target was misclassified as PlatformInstalling" >&2
  exit 1
}

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

# HARDEN-002 finding 9b: destroy must disable RDS deletion protection through
# a real applied transition (a targeted apply on just the RDS resource), with
# a snapshot identity unique to this attempt -- never by passing `-var` to
# `terraform destroy`, which is inert against a resource's prior state.
rm -f "$RDS_PREPARED_FILE"
log="$tmp/destroy-established.log"
if ! run_destroy "$log"; then
  cat "$log.out" >&2
  echo "cloud destroy on an established target must succeed" >&2
  exit 1
fi
grep -F -- '-target=aws_db_instance.postgres' "$log" | grep -F 'rds_deletion_protection=false' \
  | grep -F 'rds_skip_final_snapshot=false' >/dev/null
snapshot_line="$(grep -F -- '-target=aws_db_instance.postgres' "$log" | head -1)"
snapshot_id="$(printf '%s\n' "$snapshot_line" | grep -oE 'rds_final_snapshot_identifier=[^ ]+' | cut -d= -f2)"
case "$snapshot_id" in
  lifecycle-test-postgres-final-*) : ;;
  *)
    echo "RDS final snapshot identifier was not the expected unique per-attempt name: $snapshot_id" >&2
    exit 1
    ;;
esac
grep -F 'verify preparation: RDS deletion protection disabled' "$log.out" >/dev/null
grep -F "final snapshot $snapshot_id confirmed" "$log.out" >/dev/null
# Preparation happens before the actual destroy, not folded into it.
prepare_line_no="$(grep -n -- '-target=aws_db_instance.postgres' "$log" | head -1 | cut -d: -f1)"
destroy_line_no="$(grep -n 'infra/aws.* destroy ' "$log" | head -1 | cut -d: -f1)"
if [ -z "$destroy_line_no" ] || [ "$prepare_line_no" -ge "$destroy_line_no" ]; then
  echo "RDS destroy preparation did not run before the cloud destroy" >&2
  cat "$log" >&2
  exit 1
fi

# ADR 0003 / HARDEN-002 run 4 finding 15: after a verified PrepareDestroy the
# Destroy policy governs. The bootstrap-admin reconciliation that necessarily
# precedes the actual destroy must therefore still carry the destroy overrides,
# and they must be appended AFTER the production profile's
# rds_deletion_protection=true (injected by terraform_vars) so the Destroy policy
# wins rather than Ready policy silently re-enabling protection.
admin_apply_line="$(grep 'infra/aws.* apply ' "$log" | grep -F 'provisioner_bootstrap_admin=true' | head -1 || true)"
case "$admin_apply_line" in
  *'rds_deletion_protection=false'*) : ;;
  *)
    echo "the post-prepare bootstrap-admin apply did not carry the Destroy policy" >&2
    cat "$log" >&2
    exit 1
    ;;
esac
last_protection="$(printf '%s\n' "$admin_apply_line" | grep -oE 'rds_deletion_protection=[a-z]+' | tail -1)"
if [ "$last_protection" != "rds_deletion_protection=false" ]; then
  echo "Ready policy overrode the Destroy policy after PrepareDestroy ($last_protection)" >&2
  cat "$log" >&2
  exit 1
fi

# A second destroy attempt (e.g. retried after a prior failure elsewhere in
# the lifecycle) must mint a different snapshot identity, not reuse the
# cluster-derived constant HARDEN-002 finding 9b replaced.
log2="$tmp/destroy-established-2.log"
if ! run_destroy "$log2"; then
  cat "$log2.out" >&2
  echo "a second cloud destroy attempt must also succeed" >&2
  exit 1
fi
snapshot_line2="$(grep -F -- '-target=aws_db_instance.postgres' "$log2" | head -1)"
snapshot_id2="$(printf '%s\n' "$snapshot_line2" | grep -oE 'rds_final_snapshot_identifier=[^ ]+' | cut -d= -f2)"
if [ "$snapshot_id" = "$snapshot_id2" ]; then
  echo "two destroy attempts minted the same RDS final snapshot identifier: $snapshot_id" >&2
  exit 1
fi

# An absent target (cloud substrate never applied) has nothing to prepare and
# must not attempt the targeted apply.
rm -f "$RDS_PREPARED_FILE"
log="$tmp/destroy-absent.log"
if ! (export OUTPUT_ABSENT=1; run_destroy "$log"); then
  cat "$log.out" >&2
  echo "cloud destroy on an absent target must still succeed" >&2
  exit 1
fi
grep -F 'prepare: cloud substrate is absent, nothing to prepare' "$log.out" >/dev/null
if grep -F -- '-target=aws_db_instance.postgres' "$log" >/dev/null; then
  echo "cloud destroy attempted RDS preparation on an absent cloud substrate" >&2
  exit 1
fi

# Cloud substrate exists but this target never created an RDS instance:
# distinct from the wholly-absent case above (cloud_destroy still has real
# outputs and reaches prepare_destroy), and must also skip the targeted apply.
rm -f "$RDS_PREPARED_FILE"
log="$tmp/destroy-no-rds.log"
if ! (export RDS_ABSENT=1; run_destroy "$log"); then
  cat "$log.out" >&2
  echo "cloud destroy on a target with no RDS instance must still succeed" >&2
  exit 1
fi
grep -F 'prepare: no RDS instance for this target, nothing to prepare' "$log.out" >/dev/null
if grep -F -- '-target=aws_db_instance.postgres' "$log" >/dev/null; then
  echo "cloud destroy attempted RDS preparation when no RDS instance exists" >&2
  exit 1
fi

# ADR 0003 invariant 6 (HARDEN-002 run 5): destruction is an abort edge, not a
# forward transition. A failed or partially installed target must remain
# destructible through the public lifecycle, because lifecycle enforcement must
# never strand infrastructure.
#
# This is the case the model and the operation used to disagree about: the
# forward relation rejects `PlatformInstalling -> PreparingDestroy` (correctly --
# it describes progressive establishment), so routing destroy through `enter`
# would refuse to tear down a half-built target and leave the operator with no
# exit but manual surgery on live cloud resources.
#
# The marker is removed so the target reads as "substrate exists, platform never
# fully installed"; a future implementation that consults the phase here, or that
# gates teardown on a probe which can fail, fails this scenario. Nothing follows
# this scenario, so the harness state is not restored.
rm -f "$RDS_PREPARED_FILE"
rm -f "$PLATFORM_INSTALLED_FILE"
log="$tmp/destroy-partial-install.log"
if ! run_destroy "$log"; then
  cat "$log.out" >&2
  echo "cloud destroy on a partially installed target must succeed (invariant 6)" >&2
  exit 1
fi
grep -F 'lifecycle phase: PreparingDestroy' "$log.out" >/dev/null || {
  echo "destroy on a partially installed target did not enter the destruction phase:" >&2
  cat "$log.out" >&2
  exit 1
}
