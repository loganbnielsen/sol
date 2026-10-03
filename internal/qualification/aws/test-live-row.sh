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
INSTALL="$TMP/install"
VERSION="v0.1.0-alpha.7"
DIGEST64="$(printf 'a%.0s' $(seq 1 64))"
RUNNER="ghcr.io/example/sol-migration-runner:$VERSION@sha256:$DIGEST64"
NO_RUNNER_INSTALL="$TMP/install-no-runner"
TAG_RUNNER_INSTALL="$TMP/install-tag-runner"

mkdir -p "$ROOT/internal/qualification/aws" "$WORKSPACE/sol" "$TMP/bin"
cp "$REPO/internal/qualification/aws/live-row.sh" "$ROOT/internal/qualification/aws/"
cp "$REPO/internal/qualification/sol-under-test.sh" "$ROOT/internal/qualification/"

bundle() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/share/sol/$VERSION/platform/shared"
  printf '{\n  "components": {}\n}\n' >"$dir/share/sol/$VERSION/platform/shared/components.json"
  cat >"$dir/bin/sol" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' "${STUB_SOL_VERSION:-v0.1.0-alpha.7}"
  exit 0
fi
printf 'sol %s [runner=%s] [home=%s]\n' "$*" "${SOL_MIGRATION_RUNNER_IMAGE:-unset}" "${SOL_HOME:-unset}" >>"$SOL_LOG"
exit 0
STUB
  chmod +x "$dir/bin/sol"
}

bundle "$INSTALL"
printf '%s\n' "$RUNNER" >"$INSTALL/share/sol/$VERSION/migration-runner-image"

bundle "$NO_RUNNER_INSTALL"

bundle "$TAG_RUNNER_INSTALL"
printf 'ghcr.io/example/sol-migration-runner:%s\n' "$VERSION" >"$TAG_RUNNER_INSTALL/share/sol/$VERSION/migration-runner-image"

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
exit 0
STUB
chmod +x "$TMP/bin/docker"

run_row() {
  local name="$1"
  shift
  export AWS_LOG="$TMP/$name.aws"
  export KUBECTL_LOG="$TMP/$name.kubectl"
  export DOCKER_LOG="$TMP/$name.docker"
  export SOL_LOG="$TMP/$name.sol"
  export LOG_DIR="$TMP/$name.logs"
  : >"$AWS_LOG"
  : >"$KUBECTL_LOG"
  : >"$DOCKER_LOG"
  : >"$SOL_LOG"
  rm -rf "$LOG_DIR"
  env PATH="$TMP/bin:$PATH" \
    WORKSPACE="$WORKSPACE" TARGET=qualreg/aws/us-east-1 ECR_REGISTRY="$ECR" \
    CLUSTER=test-cluster DEPLOY_ROLE_ARN=arn:aws:iam::1:role/deploy \
    CLUSTER_ACCESS_ROLE_ARN=arn:aws:iam::1:role/access \
    SOL_INSTALL="$INSTALL" PHASE_TIMEOUT=60 "$@" \
    "$ROOT/internal/qualification/aws/live-row.sh" app >"$TMP/$name.out" 2>&1
  echo "$?" >"$TMP/$name.rc"
}

printf '\nscenario: the app phase runs the installed release bundle and hands Sol no runner\n'
run_row ok
is "exit 0" "$(cat "$TMP/ok.rc")" "0"
has "the installed bundle is named in the transcript" \
  "sol-under-test: release $VERSION at $INSTALL" "$TMP/ok.out"
has "the application images are still built and pushed by the harness" \
  "docker push $ECR/pluto/charge-svc:row-" "$TMP/ok.docker"
lacks "but the harness publishes no migration runner" \
  "sol-migration-runner" "$TMP/ok.docker"
has "Sol applies the workspace's migrations" \
  "sol migrate apply qualreg/aws/us-east-1 [runner=unset] [home=unset]" "$TMP/ok.sol"
lacks "without being asked to publish or name a runner" \
  "migrate apply qualreg/aws/us-east-1 --registry" "$TMP/ok.sol"
has "the deploy still resolves the workspace's own images from the target's registry" \
  "deploy qualreg/aws/us-east-1 --registry $ECR --image-tag row-" "$TMP/ok.sol"
has "the run identity records the bundle version" \
  "sol_version: $VERSION" "$TMP/ok.logs/sol-identity.txt"
has "and the bundle's digest-pinned migration runner" \
  "migration_runner_image: $RUNNER" "$TMP/ok.logs/sol-identity.txt"

printf '\nscenario: a dev build, a missing bundle and an unpinned runner are refused before Sol moves anything\n'
run_row dev STUB_SOL_VERSION=Sol-ed3f041f
refused dev "a development build is refused"
lacks "Sol is never asked to migrate" "migrate apply" "$TMP/dev.sol"
has "and the refusal names the installed-bundle rule" \
  "which is a development build" "$TMP/dev.out"

run_row missing SOL_INSTALL=
refused missing "a missing SOL_INSTALL is refused"
lacks "Sol is never invoked at all" "sol " "$TMP/missing.sol"
has "and the refusal says what to set" "set SOL_INSTALL" "$TMP/missing.out"

run_row norunner SOL_INSTALL="$NO_RUNNER_INSTALL"
refused norunner "a bundle with no runner reference is refused"
lacks "Sol is never asked to migrate" "migrate apply" "$TMP/norunner.sol"
has "and the refusal names the missing file" "records no migration runner" "$TMP/norunner.out"

run_row tagrunner SOL_INSTALL="$TAG_RUNNER_INSTALL"
refused tagrunner "a bundle whose runner is a tag is refused"
lacks "Sol is never invoked with it" "migrate apply" "$TMP/tagrunner.sol"
has "and the refusal names the digest boundary" "not a digest reference" "$TMP/tagrunner.out"

printf '\n'
if [ "$fail" -gt 0 ]; then
  printf 'live-row self-test: %s passed, %s failed\n' "$pass" "$fail"
  exit 1
fi
printf 'live-row self-test: %s passed\n' "$pass"
