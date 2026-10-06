#!/usr/bin/env bash
# Regression tests for the pre-promotion migration-runner resolution check.
#
# The check establishes that the exact runner digest the candidate records still
# exists in its registry. The failure modes are the point: a digest that no
# longer resolves, an inaccessible registry, and a mutable tag offered in place
# of the digest must all refuse, and the check must not pull, build or push.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/internal/tooling/release/verify_runner_image.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"

pass=0
fail=0
ok() { printf '  [OK]   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  [FAIL] %s\n' "$1"; fail=$((fail + 1)); }

GOOD="ghcr.io/example/sol-migration-runner@sha256:$(printf 'a%.0s' $(seq 1 64))"
OTHER="ghcr.io/example/sol-migration-runner@sha256:$(printf 'b%.0s' $(seq 1 64))"
TAG="ghcr.io/example/sol-migration-runner:latest"

export STUB_GOOD="$GOOD"
export STUB_DOCKER_LOG="$TMP/docker.log"
cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DOCKER_LOG"
case "$1 $2" in
  "buildx imagetools") ref="$4" ;;
  "manifest inspect") ref="$3" ;;
  *) exit 1 ;;
esac
[ "$ref" = "$STUB_GOOD" ] && exit 0
exit 1
STUB
chmod +x "$BIN/docker"

write_candidate() {
  local runner="$1" out="$2"
  printf '{"version":"v0.1.0-alpha.9","revision":"%s","bundle":"b.tar.gz","bundle_sha256":"%s","runner_image":"%s"}\n' \
    "$(printf 'c%.0s' $(seq 1 40))" "$(printf 'd%.0s' $(seq 1 64))" "$runner" >"$out"
}

write_candidate "$GOOD" "$TMP/good.json"
if PATH="$BIN:$PATH" "$SCRIPT" "$TMP/good.json" >/dev/null 2>&1; then
  ok "a recorded runner digest that resolves passes"
else
  no "a recorded runner digest that resolves passes"
fi

write_candidate "$OTHER" "$TMP/gone.json"
if PATH="$BIN:$PATH" "$SCRIPT" "$TMP/gone.json" >/dev/null 2>&1; then
  no "a recorded runner digest that no longer resolves refuses"
else
  ok "a recorded runner digest that no longer resolves refuses"
fi

write_candidate "$TAG" "$TMP/tag.json"
if PATH="$BIN:$PATH" "$SCRIPT" "$TMP/tag.json" >/dev/null 2>&1; then
  no "a mutable tag is refused"
else
  ok "a mutable tag is refused"
fi

if grep -Eq '(^|[[:space:]])(pull|push|build)([[:space:]]|$)' "$STUB_DOCKER_LOG"; then
  no "the check never pulls, builds or pushes"
else
  ok "the check never pulls, builds or pushes"
fi
if grep -q 'buildx imagetools inspect' "$STUB_DOCKER_LOG"; then
  ok "the check resolves the manifest by digest"
else
  no "the check resolves the manifest by digest"
fi

printf '\nrunner image resolution: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
