#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$HERE/local-qual.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STUB_DIR="$TMP/stubs"
WS="$TMP/ws"
mkdir -p "$STUB_DIR" "$WS"
printf 'project: local-qual-test\n' >"$WS/sol.yml"

cat >"$STUB_DIR/k3d" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "version ") printf 'k3d version v5.6.0\n' ;;
  "cluster list")
    printf '%s\n' "${STUB_K3D_CLUSTERS:-}"
    exit "${STUB_K3D_LIST_RC:-0}"
    ;;
  "cluster get") exit "${STUB_K3D_GET_RC:-1}" ;;
  "kubeconfig get") printf 'apiVersion: v1\nkind: Config\nclusters: []\n' ;;
esac
exit 0
STUB

cat >"$STUB_DIR/kubectl" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  config)
    printf '%s\n' "${STUB_CURRENT_CONTEXT:-}"
    exit 0
    ;;
  version)
    printf 'Client Version: v1.29.0\n'
    exit 0
    ;;
esac
printf 'stub kubectl %s\n' "$*"
exit 0
STUB

cat >"$STUB_DIR/helm" <<'STUB'
#!/usr/bin/env bash
printf 'stub helm %s\n' "$*"
exit 0
STUB

cat >"$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  version)
    printf '24.0.0\n'
    exit 0
    ;;
  ps)
    printf '%s\n' "${STUB_DOCKER_PS:-}"
    exit "${STUB_DOCKER_PS_RC:-0}"
    ;;
esac
exit 0
STUB

cat >"$STUB_DIR/sol" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_SOL_LOG:?STUB_SOL_LOG is not set}"
if [ "${1:-}" = "--version" ]
then
  printf 'v0.0.0-test\n'
fi
exit "${STUB_SOL_RC:-0}"
STUB

chmod +x "$STUB_DIR"/*

REDUCED="$TMP/reduced"
mkdir -p "$REDUCED"
for tool in k3d kubectl docker sol
do
  ln -s "$STUB_DIR/$tool" "$REDUCED/$tool"
done

pass=0
ok() {
  printf '  [OK]   %s\n' "$1"
  pass=$((pass + 1))
}
bad() {
  printf '  [FAIL] %s\n' "$1" >&2
  exit 1
}

RUN_PATH="$STUB_DIR:/usr/bin:/bin"
RUN_LOG="$TMP/log"
RUN_CLUSTER="sol-local"
RUN_ROWS=""
PHASE_OUT=""
RC=0

run_phase() {
  local phase="$1"
  PHASE_OUT="$TMP/phase-$phase.$RANDOM.out"
  RC=0
  PATH="$RUN_PATH" LOG_DIR="$RUN_LOG" WORKSPACE="$WS" SOL="$STUB_DIR/sol" \
    CLUSTER="$RUN_CLUSTER" ROWS_SH="$RUN_ROWS" \
    bash "$HARNESS" "$phase" >"$PHASE_OUT" 2>&1 || RC=$?
}

fresh_case() {
  RUN_LOG="$TMP/log-$1"
  ROWS_SH="${2:-}"
  RUN_CLUSTER="${3:-sol-local}"
  RUN_PATH="$STUB_DIR:/usr/bin:/bin"
  unset STUB_K3D_CLUSTERS STUB_K3D_LIST_RC STUB_K3D_GET_RC STUB_DOCKER_PS STUB_DOCKER_PS_RC
  unset STUB_CURRENT_CONTEXT STUB_SOL_RC
  export STUB_SOL_LOG="$RUN_LOG/sol.log"
  mkdir -p "$RUN_LOG"
  : >"$STUB_SOL_LOG"
}

verdict_of() {
  awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$2"
}

expect_ok() { [ "$RC" -eq 0 ] || bad "$1 (exit $RC): $(tr '\n' '|' <"$PHASE_OUT" | cut -c1-300)"; }
expect_fail() { [ "$RC" -ne 0 ] || bad "$1 (expected non-zero, got 0)"; }
contains() {
  grep -qF -- "$2" "$1" || bad "$3 (wanted: $2 in $(basename "$1"))"
}
lacks() {
  if grep -qF -- "$2" "$1"
  then
    bad "$3 (unwanted: $2 in $(basename "$1"))"
  fi
}

fresh_case preflight
export STUB_CURRENT_CONTEXT="sol-qual-stale-deploy"
run_phase preflight
expect_ok "preflight succeeds with the tools present"
[ -f "$RUN_LOG/run-identity.txt" ] || bad "preflight writes the run identity"
contains "$RUN_LOG/run-identity.txt" "sol-qual-stale-deploy" "the ambient context is recorded, not silently used"
ok "preflight records the run identity and the ambient context"

RUN_PATH="$REDUCED:/usr/bin:/bin"
run_phase preflight
expect_fail "preflight refuses when a required tool is missing"
contains "$PHASE_OUT" "helm not found in PATH" "the missing prerequisite is named"
ok "preflight fails closed and names the missing tool"

fresh_case infra
run_phase infra
expect_ok "infra completes"
contains "$STUB_SOL_LOG" "local deploy" "the harness drives sol local deploy"
[ -f "$RUN_LOG/local-deploy.log" ] || bad "infra captures its own log"
[ -f "$RUN_LOG/namespaces.txt" ] || bad "infra captures the namespace inventory"
[ -f "$RUN_LOG/helm-releases.txt" ] || bad "infra captures the Helm releases"
ok "infra drives sol local deploy and captures the cluster inventory"

fresh_case rows
run_phase rows
expect_fail "rows without a driver is refused"
contains "$PHASE_OUT" "FEAT-132" "the refusal names the missing reference applications"
ok "rows fail closed until the reference applications supply a driver"

fresh_case teardown-absent
export STUB_K3D_CLUSTERS=""
export STUB_DOCKER_PS=""
run_phase teardown
expect_ok "teardown succeeds once absence is established"
contains "$STUB_SOL_LOG" "local down" "teardown stops Sol's port-forwards"
contains "$RUN_LOG/teardown-verdict.txt" "ABSENT" "absence is recorded"
ok "teardown stops Sol's port-forwards and verifies the cluster's absence"

fresh_case teardown-present
export STUB_K3D_CLUSTERS="sol-local"
run_phase teardown
expect_fail "teardown refuses a cluster that is still present"
contains "$RUN_LOG/teardown-verdict.txt" "PRESENT" "the cluster verdict is PRESENT"
ok "teardown refuses to report success while the cluster survives"

fresh_case teardown-unknown
export STUB_K3D_CLUSTERS=""
export STUB_K3D_LIST_RC=1
run_phase teardown
expect_fail "teardown refuses when the cluster list cannot be read"
[ "$(verdict_of cluster "$RUN_LOG/teardown-verdict.txt")" = "UNKNOWN" ] \
  || bad "a failed cluster read must be UNKNOWN (got: $(verdict_of cluster "$RUN_LOG/teardown-verdict.txt"))"
contains "$PHASE_OUT" "UNKNOWN" "the failure names the unestablished verdict"
ok "a failed absence read is UNKNOWN and never reported as ABSENT"

fresh_case capture
run_phase capture
expect_ok "capture succeeds on an existing bundle"
[ -f "$RUN_LOG/evidence-manifest.txt" ] || bad "capture writes the evidence manifest"
ok "capture writes an evidence manifest"

echo
echo "local-qual: all expectations hold ($pass checks)."
