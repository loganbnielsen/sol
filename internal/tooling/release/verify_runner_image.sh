#!/usr/bin/env bash
# Establish that the exact migration-runner digest a release candidate records
# still resolves in its registry.
#
# This is an availability and identity check, not a rebuild: it never pushes,
# never republishes, and never accepts a mutable tag in place of the recorded
# digest. Promotion runs it so that every Sol-owned artifact that made up the
# qualified candidate still exists exactly as identified when that candidate is
# promoted. A digest that is missing or inaccessible fails closed.
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

# Resolve the manifest by digest. `buildx imagetools` is preferred; `manifest
# inspect` is the fallback. Neither pulls the image, and both fail when the
# digest is absent or unreadable.
resolve() {
  "$docker" buildx imagetools inspect "$image" >/dev/null 2>&1 && return 0
  "$docker" manifest inspect "$image" >/dev/null 2>&1 && return 0
  return 1
}

if ! resolve; then
  echo "verify_runner_image: the recorded migration runner $image does not resolve in its registry; refusing to promote a candidate whose runner is gone" >&2
  exit 1
fi
echo "the recorded migration runner $image resolves"
