#!/usr/bin/env bash
# Regression tests for the pre-candidate and pre-promotion migration-runner pull
# check.
#
# The check must establish that a fresh cluster -- which has no registry
# credential -- can pull the exact digest the candidate records *anonymously*.
# The failure modes are the point:
#
#   * a private package the authenticated publisher can read but an anonymous
#     client cannot must refuse (this is #1272);
#   * a digest that no longer resolves must refuse;
#   * a mutable tag offered in place of the digest must refuse;
#   * the check must never pull layers, build or push; and
#   * it must never reuse the authenticated publisher's Docker config, or it
#     would only prove the publisher can read its own package.
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

# The credentials the release workflow used to push. A real check keeps them out
# of the registry read; the stub treats their presence as an authenticated read.
publisher_config="$TMP/publisher-docker"
mkdir -p "$publisher_config"
printf '{"auths":{"ghcr.io":{"auth":"cHVibGlzaGVyOnRva2Vu"}}}\n' >"$publisher_config/config.json"

export STUB_GOOD="$GOOD"
export STUB_DOCKER_LOG="$TMP/docker.log"
export STUB_CONFIG_LOG="$TMP/config.log"
export STUB_PUBLISHER_CONFIG="$publisher_config"

# Models GHCR: an authenticated read succeeds even for a private package, while
# an anonymous read succeeds only for a public one.
cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DOCKER_LOG"
if [ -f "${DOCKER_CONFIG:-}/config.json" ]; then auth=1; else auth=0; fi
printf 'auth=%s config=%s\n' "$auth" "${DOCKER_CONFIG:-}" >>"$STUB_CONFIG_LOG"
case "$1 $2" in
  "buildx imagetools") ref="$4" ;;
  "manifest inspect") ref="$3" ;;
  *) exit 1 ;;
esac
[ "$ref" = "$STUB_GOOD" ] || exit 1
if [ "$auth" = 1 ] && [ "${DOCKER_CONFIG:-}" = "$STUB_PUBLISHER_CONFIG" ]; then
  exit 0
fi
[ "${STUB_VISIBILITY:-private}" = "public" ] || exit 1
exit 0
STUB
chmod +x "$BIN/docker"

write_candidate() {
  local runner="$1" out="$2"
  printf '{"version":"v0.1.0-alpha.9","revision":"%s","bundle":"b.tar.gz","bundle_sha256":"%s","runner_image":"%s"}\n' \
    "$(printf 'c%.0s' $(seq 1 40))" "$(printf 'd%.0s' $(seq 1 64))" "$runner" >"$out"
}

# run_check VISIBILITY CANDIDATE: exports the publisher's config the way the
# release workflow's `docker login` leaves it, then runs the check.
run_check() {
  local visibility="$1" candidate="$2"
  export STUB_VISIBILITY="$visibility"
  : >"$STUB_CONFIG_LOG"
  PATH="$BIN:$PATH" DOCKER_CONFIG="$publisher_config" "$SCRIPT" "$candidate"
}

printf '\nfixture: the stub models authenticated versus anonymous GHCR reads\n'
STUB_VISIBILITY=private DOCKER_CONFIG="$publisher_config" "$BIN/docker" buildx imagetools inspect "$GOOD" >/dev/null 2>&1 &&
  ok "a private package is readable with the publisher's credentials" ||
  no "a private package is readable with the publisher's credentials"
STUB_VISIBILITY=private DOCKER_CONFIG="" "$BIN/docker" buildx imagetools inspect "$GOOD" >/dev/null 2>&1 &&
  no "a private package is refused without credentials" ||
  ok "a private package is refused without credentials"

write_candidate "$GOOD" "$TMP/good.json"
if run_check public "$TMP/good.json" >/dev/null 2>&1; then
  ok "a public runner digest a fresh cluster can pull passes"
else
  no "a public runner digest a fresh cluster can pull passes"
fi

write_candidate "$GOOD" "$TMP/private.json"
if run_check private "$TMP/private.json" >"$TMP/private.out" 2>&1; then
  no "a private runner the publisher alone can read refuses"
else
  ok "a private runner the publisher alone can read refuses"
fi
grep -q 'fresh cluster' "$TMP/private.out" &&
  ok "the refusal names the fresh-cluster pull contract" ||
  no "the refusal names the fresh-cluster pull contract"

# The check must have overridden the publisher's config rather than merely
# unsetting it and inheriting whatever the host's HOME holds.
if grep -q "config=$publisher_config" "$STUB_CONFIG_LOG"; then
  no "the check never reads through the publisher's credentials"
elif grep -q '^auth=0 ' "$STUB_CONFIG_LOG"; then
  ok "the check never reads through the publisher's credentials"
else
  no "the check never reads through the publisher's credentials"
fi

write_candidate "$OTHER" "$TMP/gone.json"
if run_check public "$TMP/gone.json" >/dev/null 2>&1; then
  no "a recorded runner digest that no longer resolves refuses"
else
  ok "a recorded runner digest that no longer resolves refuses"
fi

write_candidate "$TAG" "$TMP/tag.json"
if run_check public "$TMP/tag.json" >/dev/null 2>&1; then
  no "a mutable tag is refused"
else
  ok "a mutable tag is refused"
fi

if grep -Eq '(^|[[:space:]])(pull|push|build)([[:space:]]|$)' "$STUB_DOCKER_LOG"; then
  no "the check never pulls layers, builds or pushes"
else
  ok "the check never pulls layers, builds or pushes"
fi
if grep -q 'buildx imagetools inspect' "$STUB_DOCKER_LOG"; then
  ok "the check resolves the manifest by digest"
else
  no "the check resolves the manifest by digest"
fi

printf '\nrunner image resolution: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
