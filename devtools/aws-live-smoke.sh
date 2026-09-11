#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${TARGET:-dev/aws/us-east-1}"
PROFILE="${AWS_PROFILE:-Administrator}"
REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${CLUSTER:-sol-dev-lbendtly}"
LOG_DIR="${LOG_DIR:-/tmp/sol-aws-live-smoke-$(date +%Y%m%d-%H%M%S)}"
SOL="$ROOT/_build/default/cli/sol/bin/main.exe"
ACCOUNT="$(AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" aws sts get-caller-identity --query Account --output text)"

base_vars=(
  -var=base_domain=smoke-test.invalid
  -var=cluster_issuer=letsencrypt-staging
  -var=letsencrypt_email=smoke-test@example.invalid
  -var=cert_manager_irsa_role_arn=arn:aws:iam::$ACCOUNT:role/$CLUSTER-cert-manager
  -var=ingress_service_type=ClusterIP
  -var=redpanda_replicas=1
  -var=redpanda_cpu_cores=1
  -var=redpanda_memory=2Gi
  -var=redpanda_persistent_storage=false
  -var=install_postgresql=false
  -var=loki_persistent_storage=false
  -var=prometheus_persistent_storage=false
  -var=grafana_admin_password=sol-smoke-dev
)

PHASE_TIMEOUT="${PHASE_TIMEOUT:-900}" # ponytail: single knob, tune per-phase if one step needs more

say() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }

run() {
  local name="$1"; shift
  say "$name"
  if ! timeout "$PHASE_TIMEOUT" "$@" >"$LOG_DIR/$name.log" 2>&1; then
    say "FAILED: $name (last 40 lines)"
    tail -n 40 "$LOG_DIR/$name.log"
    exit 1
  fi
}

cleanup() {
  local rc=$?
  say "cleanup: base destroy"
  KUBE_CONFIG_PATH="$HOME/.kube/config" terraform -chdir="$ROOT/cli/platform/infra/base" destroy -auto-approve "${base_vars[@]}" >"$LOG_DIR/base-destroy.log" 2>&1 || true
  say "cleanup: aws destroy"
  (cd "$ROOT/examples/pluto" && AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" "$SOL" cloud destroy "$TARGET" --apply) >"$LOG_DIR/aws-destroy.log" 2>&1 || true
  say "cleanup: verify"
  AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >"$LOG_DIR/verify-eks.log" 2>&1 && rc=1 || true
  if AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" aws ec2 describe-vpcs --filters Name=tag:Name,Values="$CLUSTER" --query 'length(Vpcs)' --output text >"$LOG_DIR/verify-vpcs.log" 2>&1; then
    [ "$(cat "$LOG_DIR/verify-vpcs.log")" = "0" ] || rc=1
  fi
  say "logs: $LOG_DIR"
  exit "$rc"
}

mkdir -p "$LOG_DIR"
trap cleanup EXIT

run aws-apply bash -lc "cd '$ROOT/examples/pluto' && AWS_PROFILE='$PROFILE' AWS_REGION='$REGION' '$SOL' cloud apply '$TARGET'"
run kubeconfig aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
run nodes kubectl get nodes -o wide
run base-init terraform -chdir="$ROOT/cli/platform/infra/base" init
run cert-manager bash -lc "KUBE_CONFIG_PATH='$HOME/.kube/config' terraform -chdir='$ROOT/cli/platform/infra/base' apply -auto-approve -target=kubernetes_namespace.cert_manager -target=helm_release.cert_manager ${base_vars[*]}"
run base-apply bash -lc "KUBE_CONFIG_PATH='$HOME/.kube/config' terraform -chdir='$ROOT/cli/platform/infra/base' apply -auto-approve ${base_vars[*]}"
run pods kubectl get pods -A
run loki-ready bash -lc "kubectl -n monitoring port-forward svc/loki 3100:3100 >/tmp/sol-loki-pf.log 2>&1 & pid=\$!; sleep 5; curl -fsS http://127.0.0.1:3100/ready; kill \$pid"
# /ready only proves Loki itself is up, not that anything is being ingested.
# This proves Alloy (OBS-004, OBS-039 — Promtail's successor) is really
# scraping pod stdout by querying a namespace Sol's own app-push logging
# (obs-loki-eio) never touches (kube-system) — a non-empty result here can
# only have come from Alloy's cluster-wide DaemonSet scrape, not from any Sol
# service pushing its own logs.
run alloy-ingest bash -lc "kubectl -n monitoring port-forward svc/loki 3100:3100 >/tmp/sol-loki-pf2.log 2>&1 & pid=\$!; sleep 5; body=\$(curl -fsS --get 'http://127.0.0.1:3100/loki/api/v1/query_range' --data-urlencode 'query={namespace=\"kube-system\"}' --data-urlencode limit=1); kill \$pid; echo \"\$body\"; echo \"\$body\" | grep -q '\"result\":\[{' "
run prom-ready bash -lc "kubectl -n monitoring port-forward svc/prometheus-server 9090:80 >/tmp/sol-prom-pf.log 2>&1 & pid=\$!; sleep 5; curl -fsS http://127.0.0.1:9090/-/ready; kill \$pid"
run grafana-ready bash -lc "kubectl -n monitoring port-forward svc/grafana 3000:80 >/tmp/sol-grafana-pf.log 2>&1 & pid=\$!; sleep 5; curl -fsS http://127.0.0.1:3000/api/health; kill \$pid"

say "smoke checks passed"
