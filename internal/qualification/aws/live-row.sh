#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORKSPACE="${WORKSPACE:-$ROOT/examples/pluto}"
TARGET="${TARGET:-qualreg/aws/us-east-1}"
TARGET_FILE="$WORKSPACE/sol/environments.local.yml"
TFVARS="${TFVARS:-$ROOT/internal/qualification/aws/qual-aws-row.tfvars}"
AWS_PROFILE="${AWS_PROFILE:-sol-qual}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${CLUSTER:?Set CLUSTER to this the run EKS cluster name}"
DEPLOY_ROLE_ARN="${DEPLOY_ROLE_ARN:?Set DEPLOY_ROLE_ARN to the deploy role the target declares}"
CLUSTER_ACCESS_ROLE_ARN="${CLUSTER_ACCESS_ROLE_ARN:?Set CLUSTER_ACCESS_ROLE_ARN to the cluster-access role the target declares}"
LEDGER_PREFIX="${LEDGER_PREFIX:-sol}"
SOL="${SOL:-$ROOT/_build/default/cli/bin/main.exe}"
PHASE_TIMEOUT="${PHASE_TIMEOUT:-2400}"
APP_TAG="${APP_TAG:-row-$(date -u +%Y%m%d-%H%M%S)}"
LOG_DIR="${LOG_DIR:-/tmp/sol-aws-row-$(date +%Y%m%d-%H%M%S)}"
export AWS_PROFILE AWS_REGION APP_TAG

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
STATE_BUCKET="${STATE_BUCKET:-sol-qual5-$ACCOUNT-tfstate}"
LOCK_TABLE="${LOCK_TABLE:-sol-qual5-tflock}"
BASE_DOMAIN="${BASE_DOMAIN:-qual-aws.sol-fab.dev}"
DURABLE_ROOT="$ROOT/platform/cloud/aws/bootstrap"
ECR_REGISTRY="${ECR_REGISTRY:-$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com}"
STATE_KEY="$LEDGER_PREFIX/$TARGET/cloud.tfstate"
export ECR_REGISTRY

mkdir -p "$LOG_DIR/state"
say() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }

usage() {
  cat <<'USAGE'
live-row.sh — the AWS regression row: the application contract GCP Attempt 28 established

usage: live-row.sh PHASE      PHASE in: cloud | app | destroy | verify

required
  CLUSTER           this run's EKS cluster name
  DEPLOY_ROLE_ARN   the deploy identity whose kubeconfig the deploy uses
optional (defaults shown)
  TARGET=qualreg/aws/us-east-1   ECR_REGISTRY=<account>.dkr.ecr.us-east-1.amazonaws.com
  AWS_PROFILE=sol-qual           AWS_REGION=us-east-1
  TFVARS=internal/qualification/aws/qual-aws-row.tfvars
  SOL=_build/default/cli/bin/main.exe   WORKSPACE=examples/pluto
  PHASE_TIMEOUT=2400             LOG_DIR=/tmp/sol-aws-row-<timestamp>

phases
  cloud    cloud plan, cloud apply, the deploy identity's kubeconfig, node evidence, state capture
  app      build, ECR login and push, runtime secrets, migrate apply, deploy, the transaction
  destroy  supported teardown, then the independent inventory
  verify   the independent inventory only; invokes no teardown

The transaction is the causal path, not a health check: POST /charges returns an id, and the row
only passes when that id appears in GET /notifications, which cannot happen unless the worker
consumed the Kafka event and wrote PostgreSQL. AWS_PROFILE and TF_VAR_db_password must be in the
environment; POSTGRES_URL comes from the cluster root's own postgres_url output.
USAGE
}

run() {
  local name="$1"; shift
  say "$name"
  if ! timeout "$PHASE_TIMEOUT" "$@" >"$LOG_DIR/$name.log" 2>&1; then
    say "FAILED: $name (last 40 lines; full log $LOG_DIR/$name.log)"
    tail -n 40 "$LOG_DIR/$name.log"
    return 1
  fi
}

k8s_name() { printf '%s' "$1" | tr '_' '-'; }
image_ref() { printf '%s/pluto/%s:%s' "$ECR_REGISTRY" "$(k8s_name "$1")" "$APP_TAG"; }

target_state_bucket() {
  sed -n 's/^ *state_bucket: *//p' "$TARGET_FILE" | head -1
}

capture_state() {
  aws s3 cp "s3://$(target_state_bucket)/$STATE_KEY" "$LOG_DIR/state/cloud.tfstate" \
    >"$LOG_DIR/state/copy.log" 2>&1 || true
}

capture_kube_evidence() {
  kubectl get nodes -o wide >"$LOG_DIR/k8s-nodes.txt" 2>&1 || true
  kubectl get pods --all-namespaces -o wide >"$LOG_DIR/k8s-pods.txt" 2>&1 || true
  kubectl get events --all-namespaces --sort-by=.lastTimestamp >"$LOG_DIR/k8s-events.txt" 2>&1 || true
  kubectl get certificates --all-namespaces >"$LOG_DIR/k8s-certificates.txt" 2>&1 || true
  kubectl get applications -n argocd >"$LOG_DIR/k8s-applications.txt" 2>&1 || true
}

aws_inventory() {
  {
    printf 'clusters\n'
    aws eks list-clusters --query 'clusters' --output text
    printf 'ec2 instances tagged for this run\n'
    aws ec2 describe-instances --filters "Name=tag:Name,Values=*$CLUSTER*" \
      --query 'Reservations[].Instances[].InstanceId' --output text
    printf 'vpcs\n'
    aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$CLUSTER" \
      --query 'Vpcs[].VpcId' --output text
    printf 'rds\n'
    aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text
    printf 'ecr repositories\n'
    aws ecr describe-repositories --query 'repositories[].repositoryName' --output text
    printf 'nat gateways\n'
    aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values=*$CLUSTER*" \
      --query 'NatGateways[].NatGatewayId' --output text
    printf 'elastic ips\n'
    aws ec2 describe-addresses --query 'Addresses[].PublicIp' --output text
    printf 'load balancers\n'
    aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text
    printf 'route53 zones for the qualification domain\n'
    aws route53 list-hosted-zones --query "HostedZones[?contains(Name, 'sol-fab')].Name" --output text
  } >"$LOG_DIR/aws-inventory.txt" 2>&1
  cat "$LOG_DIR/aws-inventory.txt"
}

reconcile_durable_root() {
  local base=(-backend-config="bucket=$STATE_BUCKET" -backend-config="key=bootstrap/aws/default.tfstate"
              -backend-config="region=$AWS_REGION" -backend-config="dynamodb_table=$LOCK_TABLE"
              -backend-config="encrypt=true")
  local v=(-var="region=$AWS_REGION" -var="state_bucket=$STATE_BUCKET" -var="state_lock_table=$LOCK_TABLE"
           -var="manage_dns_zone=true" -var="base_domain=$BASE_DOMAIN")

  if aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; then
    say "bootstrap: state bucket s3://$STATE_BUCKET present"
  else
    say "bootstrap: state bucket absent -- it must exist before the durable root can store state in it"
  fi

  say "bootstrap: reconciling the durable root against its declared state"
  ( cd "$DURABLE_ROOT" && timeout "$PHASE_TIMEOUT" terraform init -input=false "${base[@]}" ) \
    >"$LOG_DIR/bootstrap.log" 2>&1 || {
      say "bootstrap FAILED at init -- see $LOG_DIR/bootstrap.log"; tail -n 20 "$LOG_DIR/bootstrap.log"; return 1;
    }

  local plan_rc=0
  ( cd "$DURABLE_ROOT" && timeout "$PHASE_TIMEOUT" terraform plan -input=false -detailed-exitcode \
      -out="$LOG_DIR/durable.tfplan" "${v[@]}" ) >>"$LOG_DIR/bootstrap.log" 2>&1 || plan_rc=$?

  case "$plan_rc" in
    0)
      say "bootstrap: durable root already matches its declared state"
      return 0
      ;;
    1)
      say "bootstrap FAILED at plan -- see $LOG_DIR/bootstrap.log"
      tail -n 20 "$LOG_DIR/bootstrap.log"
      return 1
      ;;
  esac

  ( cd "$DURABLE_ROOT" && terraform show -no-color "$LOG_DIR/durable.tfplan" ) \
    >"$LOG_DIR/durable.plan.txt" 2>&1 || true
  if grep -qE 'must be replaced|will be destroyed' "$LOG_DIR/durable.plan.txt"; then
    say "bootstrap REFUSED: the durable root's plan would replace or destroy a durable resource."
    say "  A recreated hosted zone gets different nameservers, breaking the registrar delegation, and a"
    say "  recreated bucket is the state store for every root. Review $LOG_DIR/durable.plan.txt;"
    say "  this needs a human decision, not an automatic apply."
    return 1
  fi

  say "bootstrap: applying in-place changes to the durable root (metadata only today)"
  ( cd "$DURABLE_ROOT" && timeout "$PHASE_TIMEOUT" terraform apply -input=false "$LOG_DIR/durable.tfplan" ) \
    >>"$LOG_DIR/bootstrap.log" 2>&1 || {
      say "bootstrap FAILED at apply -- see $LOG_DIR/bootstrap.log"; tail -n 20 "$LOG_DIR/bootstrap.log"; return 1;
    }
  say "bootstrap: durable root reconciled"
}

DEPLOY_KUBECONFIG="$LOG_DIR/kubeconfig-deploy.yaml"
ACCESS_KUBECONFIG="$LOG_DIR/kubeconfig-access.yaml"

ensure_contexts() {
  say "kubeconfig"
  KUBECONFIG="$DEPLOY_KUBECONFIG" aws eks update-kubeconfig --region "$AWS_REGION" \
    --name "$CLUSTER" --alias "$CLUSTER-deploy" --role-arn "$DEPLOY_ROLE_ARN" >/dev/null || return 1
  KUBECONFIG="$ACCESS_KUBECONFIG" aws eks update-kubeconfig --region "$AWS_REGION" \
    --name "$CLUSTER" --alias "$CLUSTER-access" --role-arn "$CLUSTER_ACCESS_ROLE_ARN" >/dev/null || return 1
  export KUBECONFIG="$DEPLOY_KUBECONFIG"
}

verify_identity_boundary() {
  say "identity-boundary"
  if ! kubectl --kubeconfig "$DEPLOY_KUBECONFIG" auth can-i create rolebindings \
      --namespace pluto-payments >/dev/null 2>&1; then
    say "the deploy identity cannot create rolebindings, so application operations cannot bootstrap"
    return 1
  fi
  if kubectl --kubeconfig "$ACCESS_KUBECONFIG" auth can-i create rolebindings \
      --namespace pluto-payments >/dev/null 2>&1; then
    say "the cluster-access identity can create rolebindings: the two identities are not separated,"
    say "and the row would no longer be testing the separation the platform is built on"
    return 1
  fi
  say "identity boundary holds: deploy creates rolebindings, cluster-access does not"
}

phase_cloud() {
  reconcile_durable_root || return 1
  run cloud-plan bash -c "cd '$WORKSPACE' && exec '$SOL' cloud plan '$TARGET'" || return 1
  run cloud-apply bash -c "cd '$WORKSPACE' && exec '$SOL' cloud apply '$TARGET'" || return 1
  ensure_contexts || return 1
  run nodes kubectl --kubeconfig "$ACCESS_KUBECONFIG" get nodes -o wide || return 1
  capture_kube_evidence
  capture_state
  say "the substrate and platform install completed; evidence in $LOG_DIR"
}

phase_app() {
  ensure_contexts || return 1
  verify_identity_boundary || return 1
  run app-build docker build -f app/payments/charge_svc/Dockerfile \
    -t "$(image_ref charge_svc)" "$WORKSPACE" || return 1
  run app-build-worker docker build -f app/comms/notify_worker/Dockerfile \
    -t "$(image_ref notify_worker)" "$WORKSPACE" || return 1
  run ecr-login bash -c \
    "aws ecr get-login-password --region '$AWS_REGION' | docker login --username AWS --password-stdin '$ECR_REGISTRY'" || return 1
  run app-push docker push "$(image_ref charge_svc)" || return 1
  run app-push-worker docker push "$(image_ref notify_worker)" || return 1
  capture_state
  local url
  url="$(jq -r '.outputs.postgres_url.value // empty' "$LOG_DIR/state/cloud.tfstate" 2>/dev/null)"
  if [ -z "$url" ]; then
    say "could not read the cluster root's postgres_url output, so POSTGRES_URL cannot be established"
    return 1
  fi
  export POSTGRES_URL="$url"
  export SOL_API_KEY="${SOL_API_KEY:-$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)}"
  {
    printf 'POSTGRES_URL: %s\n' "$(printf '%s' "$url" | sed 's#://[^@]*@#://***@#')"
    printf 'SOL_API_KEY: %s*** (generated for this run)\n' "$(printf '%s' "$SOL_API_KEY" | cut -c1-2)"
  } >"$LOG_DIR/app-runtime-secrets.txt" 2>&1
  run migrate-apply bash -c "cd '$WORKSPACE' && exec '$SOL' migrate apply '$TARGET' --registry '$ECR_REGISTRY'" || return 1
  deploy_namespaces="pluto-payments pluto-comms"
  say "deploy-substrate"
  for ns in $deploy_namespaces; do
    if kubectl --kubeconfig "$DEPLOY_KUBECONFIG" get rolebinding sol-deploy -n "$ns" >/dev/null 2>&1; then
      say "  $ns: sol-deploy already bound (not a clean test of the substrate prerequisite)"
    else
      say "  $ns: no sol-deploy RoleBinding yet"
    fi
  done
  run app-deploy bash -c "cd '$WORKSPACE' && exec '$SOL' deploy '$TARGET' --registry '$ECR_REGISTRY' --image-tag '$APP_TAG'" || return 1
  for ns in $deploy_namespaces; do
    if ! kubectl --kubeconfig "$DEPLOY_KUBECONFIG" get rolebinding sol-deploy -n "$ns" >/dev/null 2>&1; then
      say "the deploy completed into $ns without establishing its scoped deploy RBAC"
      return 1
    fi
  done
  say "  the deploy established the scoped deploy RBAC in every namespace it entered"
  if ! run app-transaction bash "$ROOT/internal/qualification/aws/app-transaction.sh" "$LOG_DIR"; then
    capture_kube_evidence
    return 1
  fi
  capture_kube_evidence
  capture_state
  say "the application transaction completed: a charge was accepted, the worker consumed it, and"
  say "the service read the worker's row back out of PostgreSQL"
}

phase_destroy() {
  capture_state
  run cloud-destroy bash -c "cd '$WORKSPACE' && exec '$SOL' cloud destroy '$TARGET' --apply" || return 1
  say "destroy returned success; the independent inventory decides absence"
  aws_inventory
}

case "${1:-}" in
  cloud) phase_cloud ;;
  app) phase_app ;;
  destroy) phase_destroy ;;
  verify | inventory) aws_inventory ;;
  *) usage; exit 2 ;;
esac
