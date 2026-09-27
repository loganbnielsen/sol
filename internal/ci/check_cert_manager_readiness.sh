#!/usr/bin/env bash
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

set_value() {
  printf '%s\n' "$block" | awk -v key="$1" '
    /set \{/                          { inblock = 1; name = ""; value = ""; next }
    inblock && /name[[:space:]]*=/    { name = $0;  sub(/.*=[[:space:]]*"/, "", name);  sub(/".*/, "", name) }
    inblock && /value[[:space:]]*=/   { value = $0; sub(/.*=[[:space:]]*"/, "", value); sub(/".*/, "", value) }
    inblock && /^[[:space:]]*\}/      { if (name == key) print value; inblock = 0 }
  '
}

raw_set_value() {
  printf '%s\n' "$block" | awk -v key="$1" '
    /set \{/                        { inblock = 1; name = ""; value = ""; next }
    inblock && /name[[:space:]]*=/   { name = $0; sub(/.*=[[:space:]]*"/, "", name); sub(/".*/, "", name) }
    inblock && /value[[:space:]]*=/  { value = $0; sub(/.*=[[:space:]]*/, "", value); sub(/[[:space:]]*$/, "", value) }
    inblock && /^[[:space:]]*\}/     { if (name == key) print value; inblock = 0 }
  '
}

scalar_value() {
  printf '%s\n' "$block" | awk -v key="$1" '
    $1 == key && $2 == "=" { print $3; exit }
  '
}

to_seconds() {
  local v="$1"
  case "$v" in
    *h) echo $(( ${v%h} * 3600 )) ;;
    *m) echo $(( ${v%m} * 60 )) ;;
    *s) echo "${v%s}" ;;
    *[!0-9]*) echo "" ;;
    *) echo "$v" ;;
  esac
}

[ "$(set_value installCRDs)" = "true" ] || fail "cert-manager must install its CRDs (installCRDs = true)"

enabled="$(set_value startupapicheck.enabled)"
case "${enabled:-true}" in
  false | False | "false") fail "startupapicheck must not be disabled: it is cert-manager's readiness contract" ;;
  "") ;;
esac

per_attempt_raw="$(set_value startupapicheck.timeout)"
[ -n "$per_attempt_raw" ] || fail "startupapicheck.timeout must be set explicitly (the chart default is 1m)"
per_attempt="$(to_seconds "$per_attempt_raw")"
[ -n "$per_attempt" ] || fail "startupapicheck.timeout is not a duration this guard understands: '$per_attempt_raw'"
[ "$per_attempt" -ge 300 ] || fail "startupapicheck.timeout is ${per_attempt}s; a first install needs at least 300s"

backoff_raw="$(set_value startupapicheck.backoffLimit)"
[ -n "$backoff_raw" ] || fail "startupapicheck.backoffLimit must be set explicitly"
case "$backoff_raw" in
  '' | *[!0-9]*) fail "startupapicheck.backoffLimit is not a non-negative integer: '$backoff_raw'" ;;
esac

release_timeout="$(scalar_value timeout)"
[ -n "$release_timeout" ] || fail "the release must set an explicit timeout (the provider default, 300s, bounds the post-install check)"
case "$release_timeout" in
  '' | *[!0-9]*) fail "the release timeout is not a number of seconds: '$release_timeout'" ;;
esac
worst_case=$(( (backoff_raw + 1) * per_attempt ))
if [ "$release_timeout" -le "$worst_case" ]; then
  fail "the release timeout (${release_timeout}s) must exceed the check's worst case (${worst_case}s = (backoffLimit ${backoff_raw} + 1) x ${per_attempt}s)"
fi

wait_value="$(scalar_value wait)"
[ "${wait_value:-true}" = "true" ] || fail "the release must wait for its resources (wait = true)"

leader_election="$(raw_set_value global.leaderElection.namespace)"
[ -n "$leader_election" ] || fail "global.leaderElection.namespace must be declared: the chart default is kube-system, which GKE Autopilot manages and denies, so cert-manager never leads and its post-install check cannot pass (FND-0060 / Attempt 10)"
case "$leader_election" in
  *kube-system*)
    fail "global.leaderElection.namespace must not be kube-system (found '$leader_election'): Autopilot denies workloads the create verb in that namespace, so leader election can never succeed there"
    ;;
esac
expected_ref='kubernetes_namespace.cert_manager.metadata[0].name'
[ "$leader_election" = "$expected_ref" ] || fail "global.leaderElection.namespace must be $expected_ref (found '$leader_election'): a literal, another namespace, or another resource would be a second source of truth for the namespace cert-manager is installed into"

namespace_block="$(awk '/^resource "kubernetes_namespace" "cert_manager" \{/,/^\}/' "$main_tf")"
[ -n "$namespace_block" ] || fail "the leader-election namespace references kubernetes_namespace.cert_manager, which $main_tf does not define"
namespace_name="$(printf '%s\n' "$namespace_block" | awk -F'"' '/name[[:space:]]*=/ { print $2; exit }')"
[ "$namespace_name" = "cert-manager" ] || fail "kubernetes_namespace.cert_manager names '$namespace_name', so the leader-election namespace does not resolve to cert-manager"
[ "$namespace_name" != "kube-system" ] || fail "cert-manager's own namespace must not be kube-system"

if command -v terraform >/dev/null 2>&1; then
  terraform fmt -check "$main_tf" >/dev/null 2>&1 || fail "$main_tf is not terraform-fmt clean"
fi

echo "cert-manager readiness: check enabled, ${per_attempt}s per attempt x $((backoff_raw + 1)) attempt(s) <= ${release_timeout}s release wait; wait = true, CRDs from the chart; leader election in ${namespace_name} (by reference), never kube-system."
