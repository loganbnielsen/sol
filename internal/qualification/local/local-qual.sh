#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SOL="${SOL:-$ROOT/_build/default/cli/bin/main.exe}"
WORKSPACE="${WORKSPACE:-$ROOT/examples/pluto}"
CLUSTER="${CLUSTER:-sol-local}"
LOG_DIR="${LOG_DIR:-/tmp/sol-local-qual-$(date -u +%Y%m%d-%H%M%S)}"
RUN_KUBECONFIG="$LOG_DIR/run-kubeconfig.yaml"
ROWS_SH="${ROWS_SH:-}"

say() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
fail() {
  printf 'local-qual: %s\n' "$*" >&2
  exit 1
}
need_tool() { command -v "$1" >/dev/null 2>&1 || fail "$1 not found in PATH"; }

resolve_sol() {
  if [ -x "$SOL" ]
  then
    SOL="$(cd "$(dirname "$SOL")" && pwd)/$(basename "$SOL")"
  else
    SOL="$(command -v "$SOL" || true)"
  fi
  [ -n "$SOL" ] || fail "the sol binary was not found: set SOL to an executable path"
}

assert_environment() {
  need_tool k3d
  need_tool helm
  need_tool kubectl
  need_tool docker
  resolve_sol
  [ -f "$WORKSPACE/sol.yml" ] || fail "$WORKSPACE is not a Sol workspace (no sol.yml)"
  mkdir -p "$LOG_DIR"
}

run_logged() {
  local name="$1"
  shift
  say "$name"
  if ! "$@" >"$LOG_DIR/$name.log" 2>&1
  then
    say "FAILED: $name"
    tail -n 40 "$LOG_DIR/$name.log" >&2 || true
    return 1
  fi
}

write_run_identity() {
  {
    printf 'sol_revision\t%s\n' "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"
    printf 'sol_version\t%s\n' "$("$SOL" --version 2>/dev/null || printf unknown)"
    printf 'workspace\t%s\n' "$WORKSPACE"
    printf 'cluster\t%s\n' "$CLUSTER"
    printf 'started_utc\t%s\n' "$(date -u +%FT%TZ)"
    printf 'ambient_context\t%s\n' "$(kubectl config current-context 2>/dev/null || printf none)"
    printf 'uname\t%s\n' "$(uname -srm)"
    printf 'k3d\t%s\n' "$(k3d version 2>/dev/null | head -n 1 || printf unknown)"
    printf 'helm\t%s\n' "$(helm version 2>/dev/null || printf unknown)"
    printf 'kubectl\t%s\n' "$(kubectl version --client 2>/dev/null | head -n 1 || printf unknown)"
  } >"$LOG_DIR/run-identity.txt"
}

phase_preflight() {
  assert_environment
  write_run_identity
  say "preflight ok: $WORKSPACE on cluster $CLUSTER"
  say "run identity written to $LOG_DIR/run-identity.txt"
}

phase_infra() {
  assert_environment
  ( cd "$WORKSPACE" && "$SOL" local deploy ) >"$LOG_DIR/local-deploy.log" 2>&1 || {
    say "FAILED: sol local deploy"
    tail -n 40 "$LOG_DIR/local-deploy.log" >&2 || true
    fail "sol local deploy did not complete"
  }
  k3d kubeconfig get "$CLUSTER" >"$RUN_KUBECONFIG" 2>"$LOG_DIR/run-kubeconfig.err" \
    || fail "could not extract the run kubeconfig for $CLUSTER"
  KUBECONFIG="$RUN_KUBECONFIG" kubectl get ns -o name >"$LOG_DIR/namespaces.txt" 2>&1 \
    || fail "the run kubeconfig could not read namespaces"
  KUBECONFIG="$RUN_KUBECONFIG" helm list -A >"$LOG_DIR/helm-releases.txt" 2>&1 \
    || fail "the run kubeconfig could not list Helm releases"
  KUBECONFIG="$RUN_KUBECONFIG" kubectl get pods -A -o wide >"$LOG_DIR/pods.txt" 2>&1 \
    || fail "the run kubeconfig could not read pods"
  say "infra reachable through $RUN_KUBECONFIG"
}

phase_rows() {
  [ -n "$ROWS_SH" ] || fail "rows need a driver: set ROWS_SH to a script (the reference apps are FEAT-132/FEAT-133)"
  [ -f "$ROWS_SH" ] || fail "ROWS_SH=$ROWS_SH does not exist"
  LOG_DIR="$LOG_DIR" WORKSPACE="$WORKSPACE" SOL="$SOL" RUN_KUBECONFIG="$RUN_KUBECONFIG" \
    KUBECONFIG="${KUBECONFIG:-$RUN_KUBECONFIG}" bash "$ROWS_SH"
}

phase_capture() {
  [ -d "$LOG_DIR" ] || fail "nothing to capture: $LOG_DIR does not exist"
  {
    for file in "$LOG_DIR"/*/* "$LOG_DIR"/*
    do
      [ -f "$file" ] || continue
      printf '%s\t%s\n' "$(wc -c <"$file" | tr -d ' ')" "${file#"$LOG_DIR/"}"
    done
  } | sort -u >"$LOG_DIR/evidence-manifest.txt"
  say "captured $(wc -l <"$LOG_DIR/evidence-manifest.txt" | tr -d ' ') entries in $LOG_DIR/evidence-manifest.txt"
}

cluster_verdict() {
  local listed
  if ! listed="$(k3d cluster list 2>/dev/null)"
  then
    printf 'UNKNOWN'
    return 0
  fi
  if printf '%s\n' "$listed" | awk -v c="$CLUSTER" '$1 == c { found = 1 } END { exit !found }'
  then
    printf 'PRESENT'
  else
    printf 'ABSENT'
  fi
}

container_verdict() {
  local names
  if ! names="$(docker ps -a --filter "name=k3d-$CLUSTER" --format '{{.Names}}' 2>/dev/null)"
  then
    printf 'UNKNOWN'
    return 0
  fi
  if [ -n "$names" ]
  then
    printf 'PRESENT'
  else
    printf 'ABSENT'
  fi
}

phase_teardown() {
  assert_environment
  ( cd "$WORKSPACE" && "$SOL" local down ) >"$LOG_DIR/local-down.log" 2>&1 \
    || fail "sol local down failed"
  k3d cluster delete "$CLUSTER" >"$LOG_DIR/cluster-delete.log" 2>&1 \
    || fail "k3d cluster delete $CLUSTER failed"
  local clusters containers
  clusters="$(cluster_verdict)"
  containers="$(container_verdict)"
  printf 'cluster\t%s\ncontainers\t%s\n' "$clusters" "$containers" >"$LOG_DIR/teardown-verdict.txt"
  case "$clusters/$containers" in
    ABSENT/ABSENT) say "teardown verified: ABSENT" ;;
    */PRESENT | PRESENT/*) fail "teardown left the target running (cluster=$clusters containers=$containers)" ;;
    *) fail "teardown verdict UNKNOWN (cluster=$clusters containers=$containers); absence was not established" ;;
  esac
}

case "${1:-all}" in
  preflight) phase_preflight ;;
  infra) phase_infra ;;
  rows) phase_rows ;;
  capture) phase_capture ;;
  teardown) phase_teardown ;;
  all)
    phase_preflight
    phase_infra
    phase_capture
    ;;
  *) fail "unknown phase '${1:-}': preflight | infra | rows | capture | teardown | all" ;;
esac
