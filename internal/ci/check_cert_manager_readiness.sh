#!/usr/bin/env bash
# FND-0010: cert-manager's own readiness check must get its designed budget, and the
# Terraform wait must outlast it.
#
# cert-manager's chart runs a post-install `startupapicheck` Job that dry-run creates a
# Certificate so the API server has to call the validating webhook, polling every 5s until
# it answers. It cannot pass until cainjector has injected the CA bundle. The Helm
# provider's `timeout` (default 300s) bounds that hook's wait too, so a release that does
# not set it gives up on a check cert-manager designed to keep trying -- which is exactly
# how every GCP attempt failed the platform apply:
#
#   Error: failed post-install: 1 error occurred: * timed out waiting for the condition
#
# while the check was still polling and reporting `x509: certificate signed by unknown
# authority` (FND-0010; Attempts 4, 5, 8, 9).
#
# FND-0060 added the second half of the same contract: leader election has to happen in
# cert-manager's own namespace. The chart's default (`global.leaderElection.namespace:
# kube-system`) is what the components used in Attempt 10, and GKE Autopilot denies it -- so
# the controller and cainjector never led, cainjector never injected the webhook caBundle,
# and the check could not pass no matter how long its budget was.
#
# This guard is deliberately structural: it runs no terraform beyond `fmt -check` (which
# parses the HCL), and it pins the *contract* the live failure violated --
#   the check is enabled,
#   its per-attempt budget is a real budget,
#   and the release wait is strictly longer than the check's worst case.
# It cannot pin what a live cluster does; that is the qualification run's job.
#
# Usage: internal/ci/check_cert_manager_readiness.sh [repo-root]
set -euo pipefail

root="${1:-.}"
main_tf="$root/platform/cloud/modules/platform/main.tf"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[ -f "$main_tf" ] || fail "$main_tf is missing"

block="$(awk '/^resource "helm_release" "cert_manager" \{/,/^\}/' "$main_tf")"
[ -n "$block" ] || fail "no helm_release.cert_manager block in $main_tf"

# The value of a `set { name = "<key>" ... value = "<value>" }` inside the block.
set_value() {
  printf '%s\n' "$block" | awk -v key="$1" '
    /set \{/                          { inblock = 1; name = ""; value = ""; next }
    inblock && /name[[:space:]]*=/    { name = $0;  sub(/.*=[[:space:]]*"/, "", name);  sub(/".*/, "", name) }
    inblock && /value[[:space:]]*=/   { value = $0; sub(/.*=[[:space:]]*"/, "", value); sub(/".*/, "", value) }
    inblock && /^[[:space:]]*\}/      { if (name == key) print value; inblock = 0 }
  '
}

# The raw right-hand side of `set { name = "<key>" ... value = <rhs> }`, quoted or not. The
# leader-election value is a *reference* to the namespace resource rather than a string, so
# set_value (which strips quotes) cannot see it.
raw_set_value() {
  printf '%s\n' "$block" | awk -v key="$1" '
    /set \{/                        { inblock = 1; name = ""; value = ""; next }
    inblock && /name[[:space:]]*=/   { name = $0; sub(/.*=[[:space:]]*"/, "", name); sub(/".*/, "", name) }
    inblock && /value[[:space:]]*=/  { value = $0; sub(/.*=[[:space:]]*/, "", value); sub(/[[:space:]]*$/, "", value) }
    inblock && /^[[:space:]]*\}/     { if (name == key) print value; inblock = 0 }
  '
}

# A scalar attribute of the release itself, e.g. `timeout = 1800`.
scalar_value() {
  printf '%s\n' "$block" | awk -v key="$1" '
    $1 == key && $2 == "=" { print $3; exit }
  '
}

to_seconds() { # 10m | 600s | 900 -> seconds
  local v="$1"
  case "$v" in
    *h) echo $(( ${v%h} * 3600 )) ;;
    *m) echo $(( ${v%m} * 60 )) ;;
    *s) echo "${v%s}" ;;
    *[!0-9]*) echo "" ;;
    *) echo "$v" ;;
  esac
}

# 1. The CRDs still come from the chart: everything after cert-manager needs them.
[ "$(set_value installCRDs)" = "true" ] || fail "cert-manager must install its CRDs (installCRDs = true)"

# 2. The check stays enabled. Disabling it would remove the only signal that the webhook
#    is usable, which is the one thing this guard exists to keep.
enabled="$(set_value startupapicheck.enabled)"
case "${enabled:-true}" in
  false | False | "false") fail "startupapicheck must not be disabled: it is cert-manager's readiness contract" ;;
  "") ;;
esac

# 3. Its per-attempt budget must be a real one, not the 1-minute chart default.
per_attempt_raw="$(set_value startupapicheck.timeout)"
[ -n "$per_attempt_raw" ] || fail "startupapicheck.timeout must be set explicitly (the chart default is 1m)"
per_attempt="$(to_seconds "$per_attempt_raw")"
[ -n "$per_attempt" ] || fail "startupapicheck.timeout is not a duration this guard understands: '$per_attempt_raw'"
[ "$per_attempt" -ge 300 ] || fail "startupapicheck.timeout is ${per_attempt}s; a first install needs at least 300s"

# 4. Retries stay bounded and explicit.
backoff_raw="$(set_value startupapicheck.backoffLimit)"
[ -n "$backoff_raw" ] || fail "startupapicheck.backoffLimit must be set explicitly"
case "$backoff_raw" in
  '' | *[!0-9]*) fail "startupapicheck.backoffLimit is not a non-negative integer: '$backoff_raw'" ;;
esac

# 5. The release wait must be strictly longer than the check's worst case, or Terraform
#    cuts the check short -- the exact failure this ticket is about.
release_timeout="$(scalar_value timeout)"
[ -n "$release_timeout" ] || fail "the release must set an explicit timeout (the provider default, 300s, bounds the post-install check)"
case "$release_timeout" in
  '' | *[!0-9]*) fail "the release timeout is not a number of seconds: '$release_timeout'" ;;
esac
worst_case=$(( (backoff_raw + 1) * per_attempt ))
if [ "$release_timeout" -le "$worst_case" ]; then
  fail "the release timeout (${release_timeout}s) must exceed the check's worst case (${worst_case}s = (backoffLimit ${backoff_raw} + 1) x ${per_attempt}s)"
fi

# 6. The chart's resources must be ready before its own post-install check runs, so the
#    wait is load-bearing rather than incidental.
wait_value="$(scalar_value wait)"
[ "${wait_value:-true}" = "true" ] || fail "the release must wait for its resources (wait = true)"

# 7. FND-0060: leader election must be declared, and it must be cert-manager's own namespace.
leader_election="$(raw_set_value global.leaderElection.namespace)"
[ -n "$leader_election" ] || fail "global.leaderElection.namespace must be declared: the chart default is kube-system, which GKE Autopilot manages and denies, so cert-manager never leads and its post-install check cannot pass (FND-0060 / Attempt 10)"
case "$leader_election" in
  *kube-system*)
    fail "global.leaderElection.namespace must not be kube-system (found '$leader_election'): Autopilot denies workloads the create verb in that namespace, so leader election can never succeed there"
    ;;
esac
expected_ref='kubernetes_namespace.cert_manager.metadata[0].name'
[ "$leader_election" = "$expected_ref" ] || fail "global.leaderElection.namespace must be $expected_ref (found '$leader_election'): a literal, another namespace, or another resource would be a second source of truth for the namespace cert-manager is installed into"

# 8. ...and that reference must resolve, in this file, to cert-manager's namespace.
namespace_block="$(awk '/^resource "kubernetes_namespace" "cert_manager" \{/,/^\}/' "$main_tf")"
[ -n "$namespace_block" ] || fail "the leader-election namespace references kubernetes_namespace.cert_manager, which $main_tf does not define"
namespace_name="$(printf '%s\n' "$namespace_block" | awk -F'"' '/name[[:space:]]*=/ { print $2; exit }')"
[ "$namespace_name" = "cert-manager" ] || fail "kubernetes_namespace.cert_manager names '$namespace_name', so the leader-election namespace does not resolve to cert-manager"
[ "$namespace_name" != "kube-system" ] || fail "cert-manager's own namespace must not be kube-system"

# The HCL must also still parse.
if command -v terraform >/dev/null 2>&1; then
  terraform fmt -check "$main_tf" >/dev/null 2>&1 || fail "$main_tf is not terraform-fmt clean"
fi

echo "cert-manager readiness: check enabled, ${per_attempt}s per attempt x $((backoff_raw + 1)) attempt(s) <= ${release_timeout}s release wait; wait = true, CRDs from the chart; leader election in ${namespace_name} (by reference), never kube-system."
