#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  [OK]   %s\n' "$1"; pass=$((pass + 1)); }
no() {
  printf '  [FAIL] %s\n           expected: %s\n           actual:   %s\n' "$1" "$2" "$3"
  fail=$((fail + 1))
}
has() { if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else no "$1" "contains: $2" "$(tr '\n' '|' <"$3" 2>/dev/null | cut -c1-200)"; fi; }
lacks() { if grep -qF -- "$2" "$3" 2>/dev/null; then no "$1" "absent: $2" "present"; else ok "$1"; fi; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$3" "$2"; fi; }
exists() { if [ -f "$2" ]; then ok "$1"; else no "$1" "file exists: $2" "missing"; fi; }
refused() { if [ "$(cat "$TMP/$1.rc" 2>/dev/null)" != "0" ]; then ok "$2"; else no "$2" "non-zero" "0"; fi; }

ROOT="$TMP/root"
WORKSPACE="$TMP/workspace"
mkdir -p "$ROOT/internal/qualification/aws" "$ROOT/internal/qualification/transport" \
  "$ROOT/internal/tooling/release" "$ROOT/platform/cloud/aws/bootstrap" "$WORKSPACE/sol" "$TMP/bin"
cp "$REPO/internal/qualification/aws/live-row.sh" "$ROOT/internal/qualification/aws/"
cp "$REPO/internal/qualification/publish-migration-runner.sh" "$ROOT/internal/qualification/"
printf 'FROM scratch\nCOPY sol /usr/local/bin/sol\n' \
  >"$ROOT/internal/tooling/release/migration-runner.Dockerfile"
cat >"$ROOT/internal/qualification/aws/app-transaction.sh" <<'STUB'
#!/usr/bin/env bash
printf 'health: ok\ncharge: ch_qual01\nnotification: ch_qual01\nthe worker consumed the charge\n' \
  >"$1/app-transaction.txt"
exit 0
STUB
chmod +x "$ROOT/internal/qualification/aws/app-transaction.sh"
cat >"$ROOT/internal/qualification/aws/transport-transaction.sh" <<'STUB'
#!/usr/bin/env bash
printf 'KUBECONFIG_TRANSPORT=%s APP_NS=%s APP_SERVICE=%s SCENARIO=%s\n' \
  "${KUBECONFIG_TRANSPORT:-unset}" "${APP_NS:-unset}" "${APP_SERVICE:-unset}" "${SCENARIO:-unset}" \
  >>"$TRANSPORT_LOG"
printf 'health: ok\norder: ord_qual01\nread-back: the worker effect is visible to the service\n'
exit 0
STUB
chmod +x "$ROOT/internal/qualification/aws/transport-transaction.sh"
cat >"$ROOT/internal/qualification/transport/establish.sh" <<'STUB'
#!/usr/bin/env bash
printf 'establish %s\n' "$*" >>"$ESTABLISH_LOG"
if [ -n "${STUB_ESTABLISH_FAILS:-}" ]; then printf 'establish: refused\n' >&2; exit 1; fi
[ -n "${KUBECONFIG:-}" ] && : >"$KUBECONFIG"
exit 0
STUB
chmod +x "$ROOT/internal/qualification/transport/establish.sh"

printf 'project: scratch\n' >"$WORKSPACE/sol.yml"
cat >"$WORKSPACE/sol/environments.local.yml" <<'YAML'
qualreg:
  targets:
    aws/us-east-1:
      cluster_name: test-cluster
      state_bucket: sol-qual-test-tfstate
YAML

ECR="123456789012.dkr.ecr.us-east-1.amazonaws.com"
RUNNER_REF="$ECR/pluto/sol-migration-runner:sol-test"
DIGEST64="$(printf 'a%.0s' $(seq 1 64))"

cat >"$TMP/bin/aws" <<'STUB'
#!/usr/bin/env bash
printf 'aws %s\n' "$*" >>"$AWS_LOG"
case "$1 $2" in
  "sts get-caller-identity") printf '123456789012\n' ;;
  "s3 cp")
    dest="${@: -1}"
    mkdir -p "$(dirname "$dest")"
    printf '{"outputs":{"postgres_url":{"value":"postgres://user:qual-secret@db.example.test:5432/pluto"}}}\n' >"$dest"
    ;;
  "ecr describe-repositories")
    [ -n "${STUB_RUNNER_REPO_EXISTS:-}" ] && exit 0
    exit 1
    ;;
  "ecr create-repository")
    if [ -n "${STUB_REPO_CREATE_FAILS:-}" ]; then printf 'AccessDeniedException\n' >&2; exit 1; fi
    ;;
  "eks update-kubeconfig")
    if [ -n "${KUBECONFIG:-}" ]; then : >"$KUBECONFIG"; fi
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/aws"

cat >"$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$KUBECTL_LOG"
case " $* " in
  *" port-forward "*)
    if [ -n "${STUB_PF_NO_PORT:-}" ]; then
      sleep 5
      exit 0
    fi
    printf 'Forwarding from 127.0.0.1:54321 -> 80\n'
    while true; do sleep 1; done
    ;;
  *" auth whoami "*)
    case " $* " in
      *kubeconfig-qualifier.yaml*)
        printf '{"status":{"userInfo":{"username":"arn:aws:sts::123456789012:assumed-role/%s/session","groups":["sol:qualifiers"]}}}\n' \
          "${STUB_QUALIFIER_ROLE:-qualifier}"
        exit 0
        ;;
      *) exit 1 ;;
    esac
    ;;
  *" auth can-i create pods/portforward "*)
    case " $* " in
      *kubeconfig-access.yaml*) printf '%s\n' "${STUB_ACCESS_FORWARD:-no}" ;;
      *kubeconfig-deploy.yaml*) printf '%s\n' "${STUB_DEPLOY_FORWARD:-no}" ;;
      *kubeconfig-operator.yaml*) printf '%s\n' "${STUB_OPERATOR_FORWARD:-no}" ;;
      *kubeconfig-qualifier.yaml*) printf '%s\n' "${STUB_QUALIFIER_FORWARD:-yes}" ;;
      *) printf 'no\n' ;;
    esac
    exit 0
    ;;
  *" auth can-i "*)
    case " $* " in
      *kubeconfig-access.yaml*) exit 1 ;;
      *) exit 0 ;;
    esac
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/kubectl"

cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$CURL_LOG"
case "$*" in
  *"/health"*) printf 'ok\n' ;;
  *"-X POST"*"/charges"*) printf '{"id":"ch_qual01"}\n' ;;
  *"/notifications"*) printf '[{"id":"ch_qual01"}]\n' ;;
  *"-X POST"*"/orders"*)
    body=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -d)
          body="$2"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    id="$(printf '%s' "$body" | sed -n 's/.*"order_id":"\([^"]*\)".*/\1/p')"
    printf '{"order_id":"%s","status":"accepted"}\n' "$id"
    ;;
  *"/orders/"*)
    if [ "${STUB_ORDER_STATUS:-fulfilled}" = accepted ]; then
      printf '{"status":"accepted"}\n'
    else
      printf '{"status":"fulfilled"}\n'
    fi
    ;;
  *) printf '{}\n' ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/curl"

cat >"$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$DOCKER_LOG"
case "$1" in
  push)
    if [ "${STUB_FAIL_PUSH_FOR:-}" = "$2" ]; then exit 1; fi
    ;;
  inspect)
    ref="${@: -1}"
    if [ -n "${STUB_RUNNER_TAG_ONLY:-}" ]; then
      printf '%s\n' "$ref"
    else
      printf '%s@sha256:%s\n' "$ref" "$(printf 'a%.0s' $(seq 1 64))"
    fi
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/docker"

cat >"$TMP/bin/sol" <<'STUB'
#!/usr/bin/env bash
printf 'sol %s [runner=%s]\n' "$*" "${SOL_MIGRATION_RUNNER_IMAGE:-unset}" >>"$SOL_LOG"
exit 0
STUB
chmod +x "$TMP/bin/sol"

cat >"$TMP/bin/opam" <<'STUB'
#!/usr/bin/env bash
printf 'opam %s (SOL_RELEASE_VERSION=%s)\n' "$*" "${SOL_RELEASE_VERSION:-unset}" >>"$BUILD_LOG"
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --build-dir) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || exit 1
mkdir -p "$out/default/cli/bin"
printf 'built by the test stub\n' >"$out/default/cli/bin/main.exe"
chmod +x "$out/default/cli/bin/main.exe"
exit 0
STUB
chmod +x "$TMP/bin/opam"

cat >"$TMP/bin/terraform" <<'STUB'
#!/usr/bin/env bash
printf 'terraform %s\n' "$*" >>"$TERRAFORM_LOG"
exit 0
STUB
chmod +x "$TMP/bin/terraform"

run_row() {
  local name="$1"
  shift
  export AWS_LOG="$TMP/$name.aws"
  export KUBECTL_LOG="$TMP/$name.kubectl"
  export DOCKER_LOG="$TMP/$name.docker"
  export SOL_LOG="$TMP/$name.sol"
  export BUILD_LOG="$TMP/$name.build"
  export TRANSPORT_LOG="$TMP/$name.transport"
  export ESTABLISH_LOG="$TMP/$name.establish"
  export TERRAFORM_LOG="$TMP/$name.terraform"
  export LOG_DIR="$TMP/$name.logs"
  : >"$AWS_LOG"
  : >"$KUBECTL_LOG"
  : >"$DOCKER_LOG"
  : >"$SOL_LOG"
  : >"$BUILD_LOG"
  : >"$TRANSPORT_LOG"
  : >"$ESTABLISH_LOG"
  : >"$TERRAFORM_LOG"
  rm -rf "$LOG_DIR"
  env PATH="$TMP/bin:$PATH" \
    WORKSPACE="$WORKSPACE" TARGET=qualreg/aws/us-east-1 ECR_REGISTRY="$ECR" \
    CLUSTER=test-cluster DEPLOY_ROLE_ARN=arn:aws:iam::1:role/deploy \
    CLUSTER_ACCESS_ROLE_ARN=arn:aws:iam::1:role/access \
    SOL="$TMP/bin/sol" RUNNER_VERSION=sol-test PHASE_TIMEOUT=60 "$@" \
    "$ROOT/internal/qualification/aws/live-row.sh" app >"$TMP/$name.out" 2>&1
  echo "$?" >"$TMP/$name.rc"
}

run_phase() {
  local name="$1" phase="$2"
  shift 2
  export AWS_LOG="$TMP/$name.aws"
  export KUBECTL_LOG="$TMP/$name.kubectl"
  export DOCKER_LOG="$TMP/$name.docker"
  export SOL_LOG="$TMP/$name.sol"
  export BUILD_LOG="$TMP/$name.build"
  export TRANSPORT_LOG="$TMP/$name.transport"
  export ESTABLISH_LOG="$TMP/$name.establish"
  export TERRAFORM_LOG="$TMP/$name.terraform"
  export LOG_DIR="$TMP/$name.logs"
  : >"$AWS_LOG"
  : >"$KUBECTL_LOG"
  : >"$DOCKER_LOG"
  : >"$SOL_LOG"
  : >"$BUILD_LOG"
  : >"$TRANSPORT_LOG"
  : >"$ESTABLISH_LOG"
  : >"$TERRAFORM_LOG"
  rm -rf "$LOG_DIR"
  env PATH="$TMP/bin:$PATH" \
    WORKSPACE="$WORKSPACE" TARGET=qualreg/aws/us-east-1 ECR_REGISTRY="$ECR" \
    CLUSTER=test-cluster DEPLOY_ROLE_ARN=arn:aws:iam::1:role/deploy \
    CLUSTER_ACCESS_ROLE_ARN=arn:aws:iam::1:role/access \
    OPERATOR_ROLE_ARN=arn:aws:iam::1:role/operator QUALIFIER_ROLE=qualifier \
    SOL="$TMP/bin/sol" RUNNER_VERSION=sol-test PHASE_TIMEOUT=60 "$@" \
    "$ROOT/internal/qualification/aws/live-row.sh" "$phase" >"$TMP/$name.out" 2>&1
  echo "$?" >"$TMP/$name.rc"
}

run_transaction() {
  local name="$1" scenario="$2"
  shift 2
  export KUBECTL_LOG="$TMP/$name.kubectl"
  export CURL_LOG="$TMP/$name.curl"
  local dir="$TMP/$name.logs"
  : >"$KUBECTL_LOG"
  : >"$CURL_LOG"
  rm -rf "$dir"
  mkdir -p "$dir"
  env PATH="$TMP/bin:$PATH" \
    KUBECONFIG_TRANSPORT="$TMP/qualifier.yaml" APP_NS=pluto-payments \
    APP_SERVICE=charge-svc APP_PORT=80 SCENARIO="$scenario" \
    PF_TIMEOUT=3 READBACK_ATTEMPTS=2 READBACK_INTERVAL=1 "$@" \
    bash "$REPO/internal/qualification/aws/transport-transaction.sh" "$dir" >"$TMP/$name.out" 2>&1
  echo "$?" >"$TMP/$name.rc"
}

printf '\nscenario: the app phase — the publisher publishes, then Sol consumes\n'
run_row ok TRANSPORT=0
is "exit 0" "$(cat "$TMP/ok.rc")" "0"
has "the application images are still built and pushed by the harness" \
  "docker push $ECR/pluto/charge-svc:row-" "$TMP/ok.docker"
has "and so is the migration runner, from Sol's own release recipe" \
  "docker build -f $ROOT/internal/tooling/release/migration-runner.Dockerfile -t $RUNNER_REF" "$TMP/ok.docker"
has "pushed to a repository the publisher owns" "docker push $RUNNER_REF" "$TMP/ok.docker"
has "the runner's build stamps the Sol revision" "SOL_RELEASE_VERSION=sol-test" "$TMP/ok.build"
has "the repository the runner needs, which no service owns, is created first" \
  "aws ecr create-repository --repository-name pluto/sol-migration-runner" "$TMP/ok.aws"
has "Sol applies the workspace's migrations" "sol migrate apply qualreg/aws/us-east-1" "$TMP/ok.sol"
lacks "without being asked to publish a runner" \
  "migrate apply qualreg/aws/us-east-1 --registry" "$TMP/ok.sol"
has "because it is handed the pushed digest" \
  "migrate apply qualreg/aws/us-east-1 [runner=$RUNNER_REF@sha256:$DIGEST64]" "$TMP/ok.sol"
has "the deploy still resolves the workspace's own images from the target's registry" \
  "deploy qualreg/aws/us-east-1 --registry $ECR --image-tag row-" "$TMP/ok.sol"
has "and carries the same digest-pinned runner for its migration prerequisite" \
  "runner=$RUNNER_REF@sha256:$DIGEST64" \
  <(grep -F 'sol deploy qualreg/aws/us-east-1' "$TMP/ok.sol" | head -1)
publish_at="$(grep -n 'runner-publish' "$TMP/ok.out" | head -1 | cut -d: -f1)"
migrate_at="$(grep -n 'migrate-apply' "$TMP/ok.out" | head -1 | cut -d: -f1)"
if [ -n "$publish_at" ] && [ -n "$migrate_at" ] && [ "$publish_at" -lt "$migrate_at" ]; then
  ok "and every one of Sol's steps happens after the publisher's"
else
  no "and every one of Sol's steps happens after the publisher's" "runner-publish before migrate-apply" \
    "publish at ${publish_at:-none}, migrate at ${migrate_at:-none}"
fi

printf '\nscenario: an existing runner repository is left alone\n'
run_row existing TRANSPORT=0 STUB_RUNNER_REPO_EXISTS=1
is "exit 0" "$(cat "$TMP/existing.rc")" "0"
lacks "no repository is created when it is already there" \
  "create-repository" "$TMP/existing.aws"
has "and the runner is published into it" "docker push $RUNNER_REF" "$TMP/existing.docker"

printf '\nscenario: adversarial — an unpublishable runner stops the run before Sol is asked to move anything\n'
run_row tag TRANSPORT=0 STUB_RUNNER_TAG_ONLY=1
refused tag "a runner that resolved to no digest fails the phase"
lacks "Sol is never asked to migrate" "migrate apply" "$TMP/tag.sol"
lacks "nor to deploy" "deploy qualreg/aws/us-east-1" "$TMP/tag.sol"
has "and the refusal names the boundary rather than a tag" \
  "Sol is handed a digest, never a tag" "$TMP/tag.out"

run_row norepo TRANSPORT=0 STUB_REPO_CREATE_FAILS=1
refused norepo "a runner repository the publisher cannot create fails the phase"
lacks "Sol is never invoked at all" "sol " "$TMP/norepo.sol"
has "and the repository log is named for the operator" "runner-repository.log" "$TMP/norepo.out"

printf '\nscenario: the qualification transport is established and the identity split holds\n'
run_phase transport transport
is "exit 0" "$(cat "$TMP/transport.rc")" "0"
has "the transport principal is the one the harness names" \
  "establish test-cluster qualifier us-east-1 pluto-payments" "$TMP/transport.establish"
has "the qualifier's own assumed-role session is recorded" \
  "assumed-role/qualifier/" "$TMP/transport.logs/transport-whoami.json"
has "the cluster-access identity's surface is recorded before establishment" \
  "cluster-access create pods/portforward -n pluto-payments: no" \
  "$TMP/transport.logs/transport-separation-pre.txt"
has "and after it" \
  "cluster-access create pods/portforward -n pluto-payments: no" \
  "$TMP/transport.logs/transport-separation-post.txt"
has "so is the deploy identity's" \
  "deploy create pods/portforward -n pluto-payments: no" \
  "$TMP/transport.logs/transport-separation-post.txt"
has "so is the operator identity's" \
  "operator create pods/portforward -n pluto-payments: no" \
  "$TMP/transport.logs/transport-separation-post.txt"
has "and the qualifier can open the transport" \
  "qualifier create pods/portforward -n pluto-payments: yes" \
  "$TMP/transport.logs/transport-separation-post.txt"

printf '\nscenario: adversarial — a production identity that holds pods/portforward fails the transport\n'
run_phase broad transport STUB_ACCESS_FORWARD=yes
refused broad "a broad production surface fails the transport phase"
has "and the refusal names the separation" \
  "not separated from the identities under qualification" "$TMP/broad.out"
lacks "and no window is opened after the pre-probe fails" "establish " "$TMP/broad.establish"

printf '\nscenario: adversarial — an establishment that refuses stops before the qualifier is trusted\n'
run_phase estab transport STUB_ESTABLISH_FAILS=1
refused estab "a refused establishment fails the phase"
has "and the failure names the establishment log" "FAILED: transport-establish" "$TMP/estab.out"
lacks "and the qualifier identity is never accepted" "auth whoami" "$TMP/estab.kubectl"
lacks "and the run does not proceed to a transaction" "app-transaction" "$TMP/estab.out"

printf '\nscenario: adversarial — the transport cannot be established without naming its principal\n'
run_phase norole transport QUALIFIER_ROLE=
refused norole "a missing transport principal fails the phase"
has "and it names the missing input" "QUALIFIER_ROLE is not set" "$TMP/norole.out"
lacks "and no establishment is attempted" "establish " "$TMP/norole.establish"

printf '\nscenario: the app phase drives its transaction through the qualification transport\n'
run_phase apptransport app TRANSPORT=1
is "exit 0" "$(cat "$TMP/apptransport.rc")" "0"
has "the transport is established before Sol moves the workload" \
  "establish test-cluster qualifier us-east-1 pluto-payments" "$TMP/apptransport.establish"
has "and the transaction uses the qualifier's kubeconfig" \
  "KUBECONFIG_TRANSPORT=$TMP/apptransport.logs/kubeconfig-qualifier.yaml" "$TMP/apptransport.transport"
lacks "never the deploy identity's kubeconfig" \
  "KUBECONFIG_TRANSPORT=$TMP/apptransport.logs/kubeconfig-deploy.yaml" "$TMP/apptransport.transport"
exists "and the application's own logs are captured for the record" "$TMP/apptransport.logs/app-svc.log"
exists "for the worker too" "$TMP/apptransport.logs/app-worker.log"
establish_at="$(grep -n 'transport-establish' "$TMP/apptransport.out" | head -1 | cut -d: -f1)"
transaction_at="$(grep -n 'app-transaction' "$TMP/apptransport.out" | head -1 | cut -d: -f1)"
if [ -n "$establish_at" ] && [ -n "$transaction_at" ] && [ "$establish_at" -lt "$transaction_at" ]; then
  ok "and establishment precedes the transaction"
else
  no "and establishment precedes the transaction" "transport-establish before app-transaction" \
    "establish at ${establish_at:-none}, transaction at ${transaction_at:-none}"
fi

printf '\nscenario: the transport transaction reads the application effect back through a port-forward\n'
run_transaction txchar charges
is "exit 0" "$(cat "$TMP/txchar.rc")" "0"
has "the local endpoint is the port the forward resolved, not an assumed one" \
  "local endpoint: http://127.0.0.1:54321" "$TMP/txchar.logs/transport-transaction.txt"
has "the charge's worker effect is the read-back" \
  "read-back: the worker effect is visible to the service" "$TMP/txchar.logs/transport-transaction.txt"
has "the port-forward was opened as the qualifier kubeconfig" \
  "--kubeconfig $TMP/qualifier.yaml" "$TMP/txchar.kubectl"

run_transaction txord orders
is "exit 0" "$(cat "$TMP/txord.rc")" "0"
has "an order reaches fulfilled through its own read-back" \
  "read-back: the worker effect is visible to the service" "$TMP/txord.logs/transport-transaction.txt"
has "and the order id the service echoed was the submitted one" \
  "\"order_id\":\"ord-" "$TMP/txord.logs/transport-transaction.txt"

printf '\nscenario: adversarial — a worker that never writes is not read as success\n'
run_transaction txstuck orders STUB_ORDER_STATUS=accepted
refused txstuck "an order that never leaves accepted fails the transaction"
has "and the refusal names what was missing" \
  "the order never reached fulfilled or confirmed" "$TMP/txstuck.out"

printf '\nscenario: adversarial — a transport that never opens fails rather than curling nothing\n'
run_transaction txnoopen orders STUB_PF_NO_PORT=1
refused txnoopen "a port-forward with no local port fails the transaction"
has "and the refusal names the transport" \
  "the qualification transport did not open" "$TMP/txnoopen.out"

printf '\nscenario: the cloud and destroy phases hand Sol the row its declared var file\n'
run_phase cloudrun cloud
is "exit 0" "$(cat "$TMP/cloudrun.rc")" "0"
has "the plan carries the row's var file" \
  "cloud plan qualreg/aws/us-east-1 --var-file $ROOT/internal/qualification/aws/qual-aws-row.tfvars" \
  "$TMP/cloudrun.sol"
has "and so does the apply" \
  "cloud apply qualreg/aws/us-east-1 --var-file $ROOT/internal/qualification/aws/qual-aws-row.tfvars" \
  "$TMP/cloudrun.sol"

run_phase destroyrun destroy
is "exit 0" "$(cat "$TMP/destroyrun.rc")" "0"
has "the destroy carries the same var file, so teardown renders the applied shape" \
  "cloud destroy qualreg/aws/us-east-1 --apply --var-file $ROOT/internal/qualification/aws/qual-aws-row.tfvars" \
  "$TMP/destroyrun.sol"

printf '\nscenario: the app phase binds the scenario unit names, not the pre-campaign pair\n'
run_row alphaunits TRANSPORT=0 SVC_UNIT=orders_svc WORKER_UNIT=fulfilment_worker
is "exit 0" "$(cat "$TMP/alphaunits.rc")" "0"
has "the service image is built from the bound unit" \
  "docker build -f app/payments/orders_svc/Dockerfile" "$TMP/alphaunits.docker"
has "and pushed under its k8s name" \
  "docker push $ECR/pluto/orders-svc:row-" "$TMP/alphaunits.docker"
has "the worker image too" \
  "docker push $ECR/pluto/fulfilment-worker:row-" "$TMP/alphaunits.docker"
lacks "and no pre-campaign image is built" "charge-svc" "$TMP/alphaunits.docker"

printf '\n'
if [ "$fail" -gt 0 ]; then
  printf 'live-row self-test: %s passed, %s failed\n' "$pass" "$fail"
  exit 1
fi
printf 'live-row self-test: %s passed\n' "$pass"
