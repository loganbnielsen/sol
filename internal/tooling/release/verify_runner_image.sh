#!/usr/bin/env bash
# Establish that a fresh AWS or GCP cluster can pull the exact migration-runner
# digest a release candidate records.
#
# A fresh cluster receives no registry credentials: the migration Job names the
# digest-pinned image and configures no imagePullSecrets. So the check performs
# the registry read anonymously -- against an empty Docker config, never the
# authenticated session the publisher used to push -- and fails closed if the
# digest is missing or the GHCR package is not public.
#
# This is an availability, identity and authorization check, not a rebuild: it
# never pulls image layers, pushes, republishes, or accepts a mutable tag in
# place of the recorded digest. Candidate construction and promotion both run
# it, so the runner identity they record is one a fresh cluster can actually pull.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
candidate="${1:?usage: verify_runner_image.sh CANDIDATE_JSON}"
docker="${DOCKER:-docker}"

image="$(python3 "$HERE/promotion.py" runner-image --candidate "$candidate")"
case "$image" in
  *@sha256:*) ;;
  *)
    echo "verify_runner_image: $image is not a digest reference" >&2
    exit 1
    ;;
esac

# An empty Docker config directory makes the registry read anonymous. Reusing
# the publisher's config here would only prove that the authenticated release
# workflow can read its own package, which is exactly the assumption #1272
# falsified: a private GHCR package is readable by the publisher and not by a
# fresh cluster.
anonymous_config="$(mktemp -d)"
trap 'rm -rf "$anonymous_config"' EXIT
export DOCKER_CONFIG="$anonymous_config"

# Resolve the manifest by digest. `buildx imagetools` is preferred; `manifest
# inspect` is the fallback. Neither pulls layers, and both fail when the digest
# is absent or the anonymous read is denied.
resolve() {
  "$docker" buildx imagetools inspect "$image" >/dev/null 2>&1 && return 0
  "$docker" manifest inspect "$image" >/dev/null 2>&1 && return 0
  return 1
}

if ! resolve; then
  echo "verify_runner_image: a fresh cluster cannot pull the recorded migration runner $image anonymously; the GHCR package must be public, because a fresh cluster has no registry credential to authenticate a private one" >&2
  exit 1
fi
echo "a fresh cluster can pull the recorded migration runner $image"
