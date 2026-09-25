#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# The smoke target is generated, not committed (REFAC-105): pluto's own targets are
# user examples and must not reach into internal/. `sol/qual2/` is a path
# check_no_account_artifacts.sh refuses to see tracked, so the file stays scratch;
# it is written below and removed on exit. Overridable so a run can point at a
# scratch workspace or an existing target instead.
WORKSPACE="${WORKSPACE:-$ROOT/examples/pluto}"
TARGET="${TARGET:-qual2/aws/us-east-1}"
TARGET_FILE="$WORKSPACE/sol/$TARGET.yml"
TFVARS="$ROOT/internal/qualification/aws/smoke-test.tfvars"
# No personal defaults: the qualification run must name the account profile and
# the target's actual cluster explicitly, so a clean clone cannot accidentally
# point at someone else's account or an old cluster name.
PROFILE="${AWS_PROFILE:?Set AWS_PROFILE to a profile that can reach the target AWS account}"
REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${CLUSTER:?Set CLUSTER to the EKS cluster name for this run}"
LOG_DIR="${LOG_DIR:-/tmp/sol-aws-live-smoke-$(date +%Y%m%d-%H%M%S)}"
SOL="$ROOT/_build/default/cli/bin/main.exe"

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
  say "cleanup: target destroy"
  (cd "$WORKSPACE" && AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" "$SOL" cloud destroy "$TARGET" --apply) >"$LOG_DIR/aws-destroy.log" 2>&1 || true
  say "cleanup: verify"
  AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >"$LOG_DIR/verify-eks.log" 2>&1 && rc=1 || true
  if AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" aws ec2 describe-vpcs --filters Name=tag:Name,Values="$CLUSTER" --query 'length(Vpcs)' --output text >"$LOG_DIR/verify-vpcs.log" 2>&1; then
    [ "$(cat "$LOG_DIR/verify-vpcs.log")" = "0" ] || rc=1
  fi
  if [ -n "${WROTE_TARGET:-}" ]; then
    rm -f "$TARGET_FILE"
  fi
  say "logs: $LOG_DIR"
  exit "$rc"
}

# The smoke shape: cluster and platform only, sized by the smoke var file. The var
# file path is absolute, so it does not depend on where `sol` is invoked from.
write_target() {
  if [ -e "$TARGET_FILE" ]; then
    say "using existing target file $TARGET_FILE"
    return
  fi
  mkdir -p "$(dirname "$TARGET_FILE")"
  cat >"$TARGET_FILE" <<YAML
target:
  cluster_name: $CLUSTER
  base_domain: smoke-test.invalid
  cluster_issuer: letsencrypt-staging
  letsencrypt_email: smoke-test@example.invalid
  terraform_var_file: $TFVARS

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
  WROTE_TARGET=1
}

mkdir -p "$LOG_DIR"
trap cleanup EXIT
write_target

run aws-apply bash -lc "cd '$WORKSPACE' && AWS_PROFILE='$PROFILE' AWS_REGION='$REGION' '$SOL' cloud apply '$TARGET'"
run kubeconfig aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
run nodes kubectl get nodes -o wide
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
