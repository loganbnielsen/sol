#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PUBLISH="$HERE/publish-migration-runner.sh"
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
refused() { if [ "$(cat "$TMP/$1.rc")" != "0" ]; then ok "$2"; else no "$2" "non-zero" "0"; fi; }

ROOT="$TMP/root"
mkdir -p "$ROOT/internal/tooling/release" "$TMP/bin"
printf 'FROM scratch\nCOPY sol /usr/local/bin/sol\n' \
  >"$ROOT/internal/tooling/release/migration-runner.Dockerfile"
printf 'fake runner binary\n' >"$TMP/prebuilt-sol"
chmod +x "$TMP/prebuilt-sol"
FULL="$(printf 'a%.0s' $(seq 1 64))"
IMAGE="$TMP/reg/pluto/sol-migration-runner:sol-test"
DIGEST="@sha256:$FULL"

cat >"$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$DOCKER_LOG"
case "$1" in
  build | push)
    if [ "${STUB_FAIL_STEP:-}" = "$1" ]; then exit 1; fi
    ;;
  inspect)
    ref="${@: -1}"
    if [ -n "${STUB_TAG_ONLY:-}" ]; then
      printf '%s\n' "$ref"
    else
      printf '%s\n' "$ref@sha256:${STUB_DIGEST_HEX:-$(printf 'a%.0s' $(seq 1 64))}"
    fi
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/docker"

cat >"$TMP/bin/opam" <<'STUB'
#!/usr/bin/env bash
printf 'opam %s (SOL_RELEASE_VERSION=%s)\n' "$*" "${SOL_RELEASE_VERSION:-unset}" >>"$BUILD_LOG"
if [ "${STUB_BUILD:-ok}" != "ok" ]; then exit 1; fi
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --build-dir) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || exit 1
mkdir -p "$out/default/cli/bin"
printf 'built by the stub build\n' >"$out/default/cli/bin/main.exe"
chmod +x "$out/default/cli/bin/main.exe"
exit 0
STUB
chmod +x "$TMP/bin/opam"

run_publisher() {
  local name="$1"
  shift
  export DOCKER_LOG="$TMP/$name.docker"
  export BUILD_LOG="$TMP/$name.build"
  : >"$DOCKER_LOG"
  : >"$BUILD_LOG"
  env PATH="$TMP/bin:$PATH" "$@" >"$TMP/$name.out" 2>"$TMP/$name.err"
  echo "$?" >"$TMP/$name.rc"
}

case_publish() {
  local name="$1"
  shift
  local stub_env=()
  while [ $# -gt 0 ] && [ "${1#*=}" != "$1" ]; do
    stub_env+=("$1")
    shift
  done
  run_publisher "$name" "${stub_env[@]}" "$PUBLISH" --root "$ROOT" "$@"
}

printf '\nscenario: the publisher pushes the runner and prints its digest\n'
case_publish happy --image "$IMAGE" --version sol-test --binary "$TMP/prebuilt-sol"
is "exit 0" "$(cat "$TMP/happy.rc")" "0"
is "one line on stdout, and it is the digest reference" "$(cat "$TMP/happy.out")" "$IMAGE$DIGEST"
has "the image is built from Sol's own release recipe" \
  "build -f $ROOT/internal/tooling/release/migration-runner.Dockerfile" "$TMP/happy.docker"
has "under the reference the harness asked for" "-t $IMAGE" "$TMP/happy.docker"
has "and pushed" "push $IMAGE" "$TMP/happy.docker"
is "no build happened, because a prebuilt binary was supplied" "$(cat "$TMP/happy.build")" ""

printf '\nscenario: with no binary supplied, the publisher builds one itself\n'
case_publish built --image "$IMAGE" --version sol-abc123
is "exit 0" "$(cat "$TMP/built.rc")" "0"
has "the build stamps the Sol revision into the binary" "SOL_RELEASE_VERSION=sol-abc123" "$TMP/built.build"
has "and uses a build directory of its own, so the caller's _build is untouched" \
  "--build-dir" "$TMP/built.build"
is "the digest still reaches the caller" "$(cat "$TMP/built.out")" "$IMAGE$DIGEST"

printf '\nscenario: adversarial — a moving tag is never allowed to reach Sol\n'
case_publish tag STUB_TAG_ONLY=1 --image "$TMP/reg/pluto/sol-migration-runner:latest" \
  --version sol-test --binary "$TMP/prebuilt-sol"
refused tag "a pushed tag that resolved to no digest is refused"
is "and nothing is printed on stdout" "$(cat "$TMP/tag.out")" ""
has "the refusal says a tag is not what Sol is handed" "never a tag" "$TMP/tag.err"

case_publish short STUB_DIGEST_HEX=short --image "$IMAGE" --version sol-test --binary "$TMP/prebuilt-sol"
refused short "a truncated digest is refused"
is "and nothing is printed on stdout" "$(cat "$TMP/short.out")" ""
has "naming the shape it wanted" "<image>@sha256:<64 hex>" "$TMP/short.err"

printf '\nscenario: adversarial — an unpublishable runner is surfaced, not papered over\n'
case_publish pushfail STUB_FAIL_STEP=push --image "$IMAGE" --version sol-test --binary "$TMP/prebuilt-sol"
refused pushfail "a failed push fails the publisher"
is "and prints no digest" "$(cat "$TMP/pushfail.out")" ""
has "naming the step that failed" "docker push failed" "$TMP/pushfail.err"

case_publish buildfail STUB_BUILD=broken --image "$IMAGE" --version sol-test
refused buildfail "a failed build fails the publisher"
lacks "and no image is pushed from it" "push" "$TMP/buildfail.docker"
has "naming what it could not produce" "no runner to publish" "$TMP/buildfail.err"

case_publish nobinary --image "$IMAGE" --version sol-test --binary "$TMP/does-not-exist"
refused nobinary "a named binary that is not there is refused"
lacks "before any image work" "docker build" "$TMP/nobinary.docker"

printf '\nscenario: adversarial — the runner must identify the Sol revision it was built from\n'
case_publish noversion --image "$IMAGE" --binary "$TMP/prebuilt-sol"
refused noversion "no version is refused"
has "with the reason: the image carries the revision" "identify the Sol revision" "$TMP/noversion.err"
lacks "and nothing is published" "push" "$TMP/noversion.docker"

case_publish noimage --version sol-test --binary "$TMP/prebuilt-sol"
refused noimage "no image reference is refused"
has "naming the missing argument" "--image is required" "$TMP/noimage.err"

mkdir -p "$TMP/empty-root"
run_publisher norecipe "$PUBLISH" --root "$TMP/empty-root" --image "$IMAGE" \
  --version sol-test --binary "$TMP/prebuilt-sol"
refused norecipe "a checkout without the release recipe is refused"
has "naming the recipe it looked for" "no release recipe at" "$TMP/norecipe.err"

printf '\n'
if [ "$fail" -gt 0 ]; then
  printf 'publish-migration-runner self-test: %s passed, %s failed\n' "$pass" "$fail"
  exit 1
fi
printf 'publish-migration-runner self-test: %s passed\n' "$pass"
