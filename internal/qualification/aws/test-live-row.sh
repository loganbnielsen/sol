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
refused() { if [ "$(cat "$TMP/$1.rc" 2>/dev/null)" != "0" ]; then ok "$2"; else no "$2" "non-zero" "0"; fi; }

ROOT="$TMP/root"
WORKSPACE="$TMP/workspace"
mkdir -p "$ROOT/internal/qualification/aws" "$ROOT/internal/tooling/release" \
  "$WORKSPACE/sol" "$TMP/bin"
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
esac
exit 0
STUB
chmod +x "$TMP/bin/aws"

cat >"$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$KUBECTL_LOG"
case " $* " in
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

run_row() {
  local name="$1"
  shift
  export AWS_LOG="$TMP/$name.aws"
  export KUBECTL_LOG="$TMP/$name.kubectl"
  export DOCKER_LOG="$TMP/$name.docker"
  export SOL_LOG="$TMP/$name.sol"
  export BUILD_LOG="$TMP/$name.build"
  export LOG_DIR="$TMP/$name.logs"
  : >"$AWS_LOG"
  : >"$KUBECTL_LOG"
  : >"$DOCKER_LOG"
  : >"$SOL_LOG"
  : >"$BUILD_LOG"
  rm -rf "$LOG_DIR"
  env PATH="$TMP/bin:$PATH" \
    WORKSPACE="$WORKSPACE" TARGET=qualreg/aws/us-east-1 ECR_REGISTRY="$ECR" \
    CLUSTER=test-cluster DEPLOY_ROLE_ARN=arn:aws:iam::1:role/deploy \
    CLUSTER_ACCESS_ROLE_ARN=arn:aws:iam::1:role/access \
    SOL="$TMP/bin/sol" RUNNER_VERSION=sol-test PHASE_TIMEOUT=60 "$@" \
    "$ROOT/internal/qualification/aws/live-row.sh" app >"$TMP/$name.out" 2>&1
  echo "$?" >"$TMP/$name.rc"
}

printf '\nscenario: the app phase — the publisher publishes, then Sol consumes\n'
run_row ok
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
run_row existing STUB_RUNNER_REPO_EXISTS=1
is "exit 0" "$(cat "$TMP/existing.rc")" "0"
lacks "no repository is created when it is already there" \
  "create-repository" "$TMP/existing.aws"
has "and the runner is published into it" "docker push $RUNNER_REF" "$TMP/existing.docker"

printf '\nscenario: adversarial — an unpublishable runner stops the run before Sol is asked to move anything\n'
run_row tag STUB_RUNNER_TAG_ONLY=1
refused tag "a runner that resolved to no digest fails the phase"
lacks "Sol is never asked to migrate" "migrate apply" "$TMP/tag.sol"
lacks "nor to deploy" "deploy qualreg/aws/us-east-1" "$TMP/tag.sol"
has "and the refusal names the boundary rather than a tag" \
  "Sol is handed a digest, never a tag" "$TMP/tag.out"

run_row norepo STUB_REPO_CREATE_FAILS=1
refused norepo "a runner repository the publisher cannot create fails the phase"
lacks "Sol is never invoked at all" "sol " "$TMP/norepo.sol"
has "and the repository log is named for the operator" "runner-repository.log" "$TMP/norepo.out"

printf '\n'
if [ "$fail" -gt 0 ]; then
  printf 'live-row self-test: %s passed, %s failed\n' "$pass" "$fail"
  exit 1
fi
printf 'live-row self-test: %s passed\n' "$pass"
