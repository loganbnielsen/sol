#!/usr/bin/env bash
# FEAT-101 / DEC-049: an installed Sol release works outside a checkout.
#
# Extracts the real release archive and runs its binary in a container that can
# see nothing but that installation and the documented runtime libraries: no
# checkout mounted, a read-only root and install, no network, no SOL_HOME. It
# then runs `sol assets`, which executes the real consumers (component values,
# dashboards, Alloy, every Terraform root, the migration runner) against
# whatever root the binary resolves.
#
# Positive controls, so a pass means something:
#   1. a development build in the same container finds no assets -- there is no
#      checkout in there to find;
#   2. the release with a bundled asset removed fails -- the check reads the bundle;
#   3. the release binary placed inside a checkout, without its bundle, refuses
#      rather than reaching back to the checkout's assets.
#
# Usage: smoke_installed_release.sh <archive> <version> <runner-image> <dev-binary>
set -euo pipefail

archive="$1" version="$2" runner="$3" dev_binary="$4"
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work" "$root/.smoke-reachback"' EXIT

tar -C "$work" -xzf "$archive"
install="$work/sol-$version"
[ -x "$install/bin/sol" ] || { echo "smoke: $archive has no sol-$version/bin/sol" >&2; exit 1; }
mkdir -p "$work/dev"
cp "$dev_binary" "$work/dev/sol"

# The documented runtime dependencies, and nothing of Sol's.
image=sol-installed-smoke-runtime
docker build -q -t "$image" - >/dev/null <<'DOCKERFILE'
FROM ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 libgmp10 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE

in_container() {
  local mount="$1"; shift
  docker run --rm --network none --read-only --tmpfs /tmp -e HOME=/tmp \
    -v "$mount:/opt/sol:ro" "$image" "$@"
}

pass() { echo "  [OK]   $*"; }
die() { echo "  [FAIL] $*" >&2; exit 1; }

echo "installed-release smoke: $archive"

got="$(in_container "$install" /opt/sol/bin/sol --version)"
[ "$got" = "$version" ] || die "sol --version printed '$got', expected $version"
pass "sol --version is $version"

out="$(in_container "$install" /opt/sol/bin/sol assets)" || { echo "$out"; die "sol assets failed in the installed layout"; }
echo "$out" | sed 's/^/         /'
grep -qx "assets: installed release $version" <<<"$out" || die "not resolved as installed release $version"
grep -qx "  root: /opt/sol/share/sol/$version" <<<"$out" || die "root is not the installed bundle"
grep -qF "migration runner  $runner (published)" <<<"$out" || die "runner is not the release's published digest"
grep -qx "all assets present" <<<"$out" || die "assets incomplete"
pass "sol assets: installed bundle, every consumer ran, runner is $runner"

if in_container "$install" env SOL_HOME=/nonexistent /opt/sol/bin/sol assets >/dev/null 2>&1; then
  die "an invalid SOL_HOME fell through"
fi
pass "an invalid SOL_HOME is an error, not a fall-through"

# Control 1: nothing in the container is a checkout.
if out="$(in_container "$work/dev" /opt/sol/sol assets 2>&1)"; then
  echo "$out"; die "control: a development build found assets -- the container can see a checkout"
fi
grep -q "no Sol checkout above this binary" <<<"$out" || { echo "$out"; die "control: unexpected failure"; }
pass "control: a development build finds nothing to reach back to"

# Control 2: the check reads the bundle.
cp -a "$install" "$work/damaged"
rm -rf "$work/damaged/share/sol/$version/platform/shared/observability/dashboards"
if in_container "$work/damaged" /opt/sol/bin/sol assets >/dev/null 2>&1; then
  die "control: a bundle missing its dashboards passed"
fi
pass "control: a bundle missing an asset fails"

# Control 3: a release binary inside a checkout, without its bundle, refuses.
mkdir -p "$root/.smoke-reachback/bin"
cp "$install/bin/sol" "$root/.smoke-reachback/bin/sol"
if out="$(env -u SOL_HOME "$root/.smoke-reachback/bin/sol" assets 2>&1)"; then
  echo "$out"; die "control: a release binary used the checkout around it"
fi
grep -q "but its assets are not at" <<<"$out" || { echo "$out"; die "control: unexpected failure"; }
pass "control: a release binary never reaches back into a checkout"

echo "installed-release smoke: passed"
