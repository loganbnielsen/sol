#!/usr/bin/env bash
set -eo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$repo_root}"
export SOL_HOME="$GITHUB_WORKSPACE"
cd "$GITHUB_WORKSPACE"
mkdir -p "$SOL_HOME/.ci-bin"
ln -sf "$SOL_HOME/_build/default/cli/bin/main.exe" "$SOL_HOME/.ci-bin/sol"
export PATH="$SOL_HOME/.ci-bin:$PATH"
hash -r

sol new workspace ci_smoke
cd ci_smoke

# The workspace scaffold ships exactly one -svc plus one
# worker, and only -svc gets a ClusterIP Service -- so a real
# cross-namespace request needs a second service to call. Add a
# throwaway peer and declare the synchronous dependency on charge_svc
# (whose sol.toml is the shared template, so appending a [service]
# section is valid TOML).
sol new svc checkout/checkout
printf '\n[service]\ncalls = ["checkout/checkout_svc"]\n' >> app/payments/charge_svc/sol.toml

# No -fn app exists in the scaffold or examples
# yet, and this is the only place a real cluster is already up --
# add one here (rather than a whole new example app) to exercise
# scheduled_concurrency/backoff_limit rendering and `sol fn run`
# against a real deployed CronJob, in the same sol up pass as
# everything else so this doesn't need its own health-wait cycle.
# `sol new fn` appends _fn to the given name itself (the same way
# `sol new svc checkout/checkout` above produced checkout_svc), so
# passing "heartbeat" here (not "heartbeat_fn") is what actually
# lands at app/ops/heartbeat_fn/ -- confirmed by this job's first
# real run, which instead produced app/ops/heartbeat_fn_fn/.
sol new fn ops/heartbeat
# [service] is already open at the top of the generated file (it
# holds `schedule`); appending a second [service] header at EOF
# would be a duplicate-table TOML error, so insert into the
# existing block instead, right after `schedule = ...`.
sed -i '/^schedule = /a scheduled_concurrency = "forbid"\nbackoff_limit = 5' \
  app/ops/heartbeat_fn/sol.toml

# The scaffolded workspace pins the framework to sol.git#main, so its
# images would build this PR's scaffold against main's framework: any
# A change to an API used by the scaffold, such as `Fn.trigger`,
# could never pass. Build against the commit under test instead.
internal_ci_pin_ref="${SOL_FRAMEWORK_REF:-$(git rev-parse HEAD)}"
grep -rl 'sol-fab/sol.git#main' --include='*.opam' . \
  | xargs -r sed -i "s|sol-fab/sol.git#main|sol-fab/sol.git#${internal_ci_pin_ref}|g"
if grep -rq 'sol-fab/sol.git#main' --include='*.opam' .; then
  echo "::error::scaffolded workspace still pins sol.git#main"; exit 1
fi

eval $(opam env)
dune build

sol local infra up

# Ordinary deploy delivers secret references and never
# writes a value, so seed the workspace secrets first. `sol local
# secret set` is the only Sol path that writes one, and it creates
# the namespace it needs.
sol local secret set POSTGRES_URL \
  --value "postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev"
sol local secret set SOL_API_KEY --value dev-internal-key

sol up

# `sol local infra up` installs ingress-nginx and forwards
# the controller to localhost:8088, so the Ingress `sol up` generated
# for charge_svc must route a request end to end. A service with no
# declared ingress_host gets a per-service dev host
# (`<svc>.<ns>.localhost`), so send it as the Host header; derive the
# namespace from the cluster rather than assuming the
# workspace->namespace normalization.
ingress_ns=$(kubectl get ns -o name | sed 's|namespace/||' | grep -- '-payments$' | head -1 || true)
ingress_host="charge-svc.${ingress_ns}.localhost"
ingress_ok=0
for i in $(seq 1 30); do
  if curl -sf -H "Host: ${ingress_host}" "http://localhost:8088/health" >/dev/null; then
    echo "/health via ingress OK (Host: ${ingress_host})"
    ingress_ok=1
    break
  fi
  sleep 2
done
if [ "$ingress_ok" -ne 1 ]; then
  echo "::error::FEAT-042: /health never became reachable through the local ingress (Host: ${ingress_host})"
  exit 1
fi

# CODE_LAYER-022: verify the framework's runtime endpoints against a
# real deployed pod, not just the scaffolded /health route. /healthz
# and /metrics are registered by Sol_svc.Service, so a regression in
# that layer must fail this job rather than only showing up as a
# missing Grafana series later.
# Single source of truth for where probe() writes a response body.
# /metrics is read back below, so deriving this name in two places is
# how it came to disagree with what probe() actually wrote: `echo`
# appends a newline that tr turned into a trailing '_', leaving the
# body at /tmp/probe_metrics_.out while the check grepped
# /tmp/probe_metrics.out. printf keeps the derivation exact.
probe_out_path() {
  printf '/tmp/probe%s.out' "$(printf '%s' "$1" | tr -c '[:alnum:]' '_')"
}

probe() {
  local path=$1
  local out
  out=$(probe_out_path "$path")
  local i
  for i in $(seq 1 30); do
    if curl -sf "http://localhost:8080${path}" > "$out"; then
      echo "${path} OK"
      return 0
    fi
    sleep 2
  done
  echo "::error::golden-path smoke test: ${path} never became reachable"
  return 1
}

probe /health
probe /healthz
probe /metrics
if ! grep -Eq '# (HELP|TYPE)' "$(probe_out_path /metrics)"; then
  echo "::error::golden-path smoke test: /metrics did not return Prometheus text"
  exit 1
fi

# A declared call's network path is a pair of
# NetworkPolicies plus an injected peer URL. Assert that the deploy
# applied all three as rendered -- this covers resolution, rendering
# and apply end to end.
#
# Enforcement is deliberately NOT asserted against the live cluster
# here: the dev substrate's policy engine (kube-router on k3s v1.27.4)
# does not match `namespaceSelector` ingress rules for freshly created
# namespaces and ignores egress policy entirely, so an allow-probe is
# denied even though the policy is correct per the Kubernetes spec.
# The deterministic reproducer is in `cli/test/test_manifest_render.ml`;
# customer-cloud CNIs enforce it.
#
# Derive namespaces from the cluster rather than assuming the
# workspace->namespace normalization, so this keeps working if the
# naming rule changes.
caller_ns=$(kubectl get ns -o name | sed 's|namespace/||' | grep -- '-payments$' | head -1 || true)
peer_ns=$(kubectl get ns -o name | sed 's|namespace/||' | grep -- '-checkout$' | head -1 || true)
if [ -z "$caller_ns" ] || [ -z "$peer_ns" ]; then
  echo "::error::FEAT-041: could not locate caller ('$caller_ns') or peer ('$peer_ns') namespace"
  exit 1
fi

caller_env=$(kubectl -n "$caller_ns" get configmap charge-svc-env -o yaml 2>/dev/null || true)
for needle in "CHECKOUT_SVC_URL" "http://checkout-svc.${peer_ns}.svc.cluster.local"; do
  case "$caller_env" in
    *"$needle"*) ;;
    *) echo "::error::FEAT-041: caller ConfigMap is missing '$needle'"; exit 1 ;;
  esac
done

caller_np=$(kubectl -n "$caller_ns" get networkpolicy charge-svc-netpol -o yaml 2>/dev/null || true)
peer_np=$(kubectl -n "$peer_ns" get networkpolicy checkout-svc-netpol -o yaml 2>/dev/null || true)
for needle in "$peer_ns" "app: checkout-svc"; do
  case "$caller_np" in
    *"$needle"*) ;;
    *) echo "::error::FEAT-041: caller NetworkPolicy is missing '$needle'"; exit 1 ;;
  esac
done
for needle in "$caller_ns" "app: charge-svc" "port: 8080"; do
  case "$peer_np" in
    *"$needle"*) ;;
    *) echo "::error::FEAT-041: peer NetworkPolicy is missing '$needle'"; exit 1 ;;
  esac
done
echo "declared service-call wiring (env + NetworkPolicy pair) applied OK"

# A successful deploy must leave a content-addressed
# release record — listed by `sol releases`, carried verbatim as the
# workload's `release` label, pointed at by the current-release object,
# and not editable in place.
sol local releases > "$GITHUB_WORKSPACE/releases.txt"
grep -F 'ID' "$GITHUB_WORKSPACE/releases.txt" >/dev/null
if [ "$(wc -l < "$GITHUB_WORKSPACE/releases.txt")" -lt 2 ]; then
  echo "::error::FEAT-067: sol up recorded no release"
  exit 1
fi
listed_ids=$(awk 'NR>1 {print $1}' "$GITHUB_WORKSPACE/releases.txt" | tr '\n' ' ')

# The taxonomy label a workload carries must be one of the
# ids `sol releases` lists — that equality is the join key from a
# deploy record to its telemetry.
label_release=$(kubectl -n "$caller_ns" get deployment charge-svc -o jsonpath='{.spec.template.metadata.labels.release}' 2>/dev/null || true)
case "$label_release" in
  r-????????????????) ;;
  *) echo "::error::FEAT-069: workload release label '$label_release' is not a content-addressed release id"; exit 1 ;;
esac
case " ${listed_ids} " in
  *" ${label_release} "*) ;;
  *) echo "::error::FEAT-069: workload release label '$label_release' is not among the ids sol releases lists (${listed_ids})"; exit 1 ;;
esac

release_cm=$(kubectl -n default get configmap -l sol.dev/type=release -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ "$release_cm" != "sol-release-${label_release}" ]; then
  echo "::error::FEAT-069: release ConfigMap '$release_cm' is not named for release '$label_release'"
  exit 1
fi
pointer=$(kubectl -n default get configmap -l sol.dev/type=release-current,sol.dev/workspace=ci_smoke -o jsonpath='{.items[0].data.release_id}' 2>/dev/null || true)
if [ "$pointer" != "$label_release" ]; then
  echo "::error::FEAT-069: current-release pointer '$pointer' != workload release '$label_release'"
  exit 1
fi
if kubectl -n default patch configmap "$release_cm" -p '{"data":{"tampered":"1"}}' >/dev/null 2>&1; then
  echo "::error::FEAT-067: release ConfigMap was edited in place (immutable: true not honoured)"
  exit 1
fi
echo "release record written, listed, labelled and immutable OK"

# The same deploy also records an immutable deployment event —
# sol-deployment-<id> record whose release_id is the release above, and
# whose deployment_id is the id `sol deployments` lists. The event is
# the deploy invocation; the release is what it put in place.
sol local deployments > "$GITHUB_WORKSPACE/deployments.txt"
grep -F 'DEPLOYMENT' "$GITHUB_WORKSPACE/deployments.txt" >/dev/null
if [ "$(wc -l < "$GITHUB_WORKSPACE/deployments.txt")" -lt 2 ]; then
  echo "::error::FEAT-070: sol up recorded no deployment event"
  exit 1
fi
listed_deployment=$(awk 'NR==2 {print $1}' "$GITHUB_WORKSPACE/deployments.txt")
listed_deployment_release=$(awk 'NR==2 {print $2}' "$GITHUB_WORKSPACE/deployments.txt")
case "$listed_deployment" in
  d-*) ;;
  *) echo "::error::FEAT-070: sol deployments listed '$listed_deployment', not a deployment id"; exit 1 ;;
esac
if [ "$listed_deployment_release" != "$label_release" ]; then
  echo "::error::FEAT-070: deployment event points at '$listed_deployment_release', workload release is '$label_release'"
  exit 1
fi
# A successful apply records outcome=applied.
listed_status=$(awk 'NR==2 {print $5}' "$GITHUB_WORKSPACE/deployments.txt")
if [ "$listed_status" != "applied" ]; then
  echo "::error::FEAT-071: successful sol up recorded status '$listed_status', expected applied"
  exit 1
fi
# The record's release link is its sol.dev/release label (the JSON body
# carries it too); `sol deployments` must have listed the record that
# claims this release, named by its deployment id.
deployment_cm=$(kubectl -n default get configmap -l "sol.dev/type=deployment,sol.dev/release=${label_release}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ "$deployment_cm" != "sol-deployment-${listed_deployment}" ]; then
  echo "::error::FEAT-070: deployment record for release '$label_release' is '$deployment_cm', sol deployments listed 'sol-deployment-${listed_deployment}'"
  exit 1
fi
if kubectl -n default patch configmap "sol-deployment-${listed_deployment}" -p '{"data":{"tampered":"1"}}' >/dev/null 2>&1; then
  echo "::error::FEAT-070: deployment ConfigMap was edited in place (immutable: true not honoured)"
  exit 1
fi
echo "deployment event written, listed, joined to its release and immutable OK"

# `scheduled_concurrency` and `backoff_limit` render into the
# deployed CronJob, and `sol fn run` creates a real ad-hoc Job from
# it. Both are fast kubectl reads/creates -- no health-wait loop
# needed, unlike the HTTP-serving workloads above.
fn_ns=$(kubectl get ns -o name | sed 's|namespace/||' | grep -- '-ops$' | head -1 || true)
if [ -z "$fn_ns" ]; then
  echo "::error::FEAT-079: could not locate the heartbeat_fn namespace"
  exit 1
fi
fn_cronjob=$(kubectl -n "$fn_ns" get cronjob -o name | sed 's|cronjob.batch/||' | head -1 || true)
if [ -z "$fn_cronjob" ]; then
  echo "::error::FEAT-079: no CronJob found in namespace $fn_ns"
  exit 1
fi
fn_spec=$(kubectl -n "$fn_ns" get cronjob "$fn_cronjob" -o yaml)
case "$fn_spec" in
  *"concurrencyPolicy: Forbid"*) ;;
  *) echo "::error::FEAT-079: CronJob $fn_cronjob is missing concurrencyPolicy: Forbid"; exit 1 ;;
esac
case "$fn_spec" in
  *"backoffLimit: 5"*) ;;
  *) echo "::error::FEAT-079: CronJob $fn_cronjob is missing backoffLimit: 5"; exit 1 ;;
esac
echo "scheduled_concurrency/backoff_limit rendered into the deployed CronJob OK"

jobs_before=$(kubectl -n "$fn_ns" get jobs -o name | wc -l)
sol local fn run "ops/heartbeat_fn"
jobs_after=$(kubectl -n "$fn_ns" get jobs -o name | wc -l)
if [ "$jobs_after" -le "$jobs_before" ]; then
  echo "::error::FEAT-079: 'sol local fn run' did not create a new Job in $fn_ns"
  exit 1
fi
manual_job=$(kubectl -n "$fn_ns" get jobs -o name | sed 's|job.batch/||' | grep -- '-manual-' | head -1 || true)
if [ -z "$manual_job" ]; then
  echo "::error::FEAT-079: no manually-created Job found in $fn_ns"
  exit 1
fi
# `kubectl create job --from=cronjob/X` sets an ownerReference back
# to the source CronJob (confirmed by this job's own run) -- the
# positive check that actually matters is that the reference names
# the *right* CronJob, proving `sol fn run` really did copy from
# the deployed one rather than some other source.
job_owner_kind=$(kubectl -n "$fn_ns" get job "$manual_job" -o jsonpath='{.metadata.ownerReferences[0].kind}')
job_owner_name=$(kubectl -n "$fn_ns" get job "$manual_job" -o jsonpath='{.metadata.ownerReferences[0].name}')
if [ "$job_owner_kind" != "CronJob" ] || [ "$job_owner_name" != "$fn_cronjob" ]; then
  echo "::error::FEAT-079: manual Job $manual_job's owner is '$job_owner_kind/$job_owner_name', expected 'CronJob/$fn_cronjob'"
  exit 1
fi
echo "'sol fn run' created Job $manual_job from the deployed CronJob $fn_cronjob OK"
