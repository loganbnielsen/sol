#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${SOL_RUNNER_ROOT:-$(cd "$HERE/../.." && pwd)}"
DOCKERFILE="$ROOT/internal/tooling/release/migration-runner.Dockerfile"
IMAGE=""
VERSION="${SOL_RELEASE_VERSION:-}"
BINARY="${SOL_RUNNER_BINARY:-}"

die() {
  printf 'publish-migration-runner: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
publish-migration-runner.sh — publish the migration-runner image as the publisher, and print its digest

usage: publish-migration-runner.sh --image REF --version VERSION [--binary PATH] [--root DIR]

Sol consumes the runner by digest only (SEC-011) and never builds or publishes
it, because the deploy identity has no registry-write authority (ADR 0002). This
script is the publisher side of that boundary: it runs where the registry
credentials live — a release workflow, or a qualification harness that already
pushes the application images — and it is what names the artifact Sol is allowed
to run.

  --image REF      the reference to publish, as repository:tag. Required.
  --version VER    the Sol revision being published; stamped into the binary the
                   image carries, so the runner identifies what built it. Required.
  --binary PATH    an already-built sol binary to package. Omit to build one here
                   with SOL_RELEASE_VERSION=VER, in a build directory of its own
                   so the caller's _build (and its dev-stamped binary) is untouched.
  --root DIR       the checkout to build from and to take the release recipe from.

Prints exactly one line: the pushed image's digest reference
(<image>@sha256:<64 hex>). Progress goes to stderr. It refuses to print anything
if the pushed reference is not digest-pinned, so a moving tag can never reach Sol.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --image)
      IMAGE="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --binary)
      BINARY="${2:-}"
      shift 2
      ;;
    --root)
      ROOT="${2:-}"
      DOCKERFILE="$ROOT/internal/tooling/release/migration-runner.Dockerfile"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$IMAGE" ] || die "--image is required (the repository:tag to publish)"
[ -n "$VERSION" ] || die "--version is required: the runner image must identify the Sol revision it was built from"
[ -f "$DOCKERFILE" ] || die "no release recipe at $DOCKERFILE"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -z "$BINARY" ]; then
  printf 'publish-migration-runner: building the runner binary (SOL_RELEASE_VERSION=%s) in %s/build\n' \
    "$VERSION" "$work" >&2
  if ! ( cd "$ROOT" && SOL_RELEASE_VERSION="$VERSION" opam exec -- dune build \
           --build-dir "$work/build" cli/bin/main.exe ) >&2; then
    die "the release build failed, so there is no runner to publish"
  fi
  BINARY="$work/build/default/cli/bin/main.exe"
fi

[ -f "$BINARY" ] || die "no runner binary at $BINARY"
mkdir -p "$work/runner"
cp "$BINARY" "$work/runner/sol"
chmod +x "$work/runner/sol"

printf 'publish-migration-runner: docker build -f %s -t %s\n' "$DOCKERFILE" "$IMAGE" >&2
docker build -f "$DOCKERFILE" -t "$IMAGE" "$work/runner" >&2 || die "docker build failed"
docker push "$IMAGE" >&2 || die "docker push failed"

if ! digest="$(docker inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null)"; then
  die "could not read the pushed runner's digest from $IMAGE"
fi
[ -n "$digest" ] || die "the pushed runner $IMAGE reported no digest"

case "$digest" in
  *@sha256:*) ;;
  *) die "the pushed runner $IMAGE resolved to $digest, which carries no digest; Sol is handed a digest, never a tag" ;;
esac
printf '%s' "$digest" | grep -Eq '@sha256:[0-9a-f]{64}$' \
  || die "the pushed runner resolved to $digest, which is not <image>@sha256:<64 hex>"

printf '%s\n' "$digest"
