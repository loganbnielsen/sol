#!/usr/bin/env bash
# Prepare the Sol OCaml framework in the current opam switch (DEC-025).
#
# THE canonical bootstrap. CI and developer setup both invoke this rather than
# each carrying their own `opam pin add` list, so there is exactly one definition
# of "the Sol development switch".
#
# Why this exists: `sol new workspace` no longer vendors framework source into the
# generated workspace. A workspace consumes the framework the way any other OCaml
# project does -- through installed opam packages. For Sol's own repository that
# means installing the framework packages from *this checkout*, so the test suite
# exercises the same package boundary a user consumes.
#
# This is Sol's *development* bootstrap (the `#main`-equivalent channel). Released
# users do not run it: they declare versioned framework packages and let opam
# resolve them. See DEC-025 and RELEASE-005.
#
# Usage:  bash cli/platform/local/scripts/prepare-framework-deps.sh
#
# Idempotent: re-running re-pins to the current checkout and reinstalls.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOL_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# The framework's supported application API plus the installable internal
# packages. Pinning all of them keeps the whole train resolving from this
# checkout -- a half-pinned switch would silently mix a local sol-svc with a
# released sol-obs.
FRAMEWORK_PACKAGES=(
  sol-runtime
  sol-env
  sol-obs
  kafka-eio-service
  sol-svc
  sol-worker
  sol-fn
  sol-jobs
)

echo "Preparing Sol framework dev dependencies from: $SOL_ROOT"

for pkg in "${FRAMEWORK_PACKAGES[@]}"; do
  if [ ! -f "$SOL_ROOT/$pkg.opam" ]; then
    echo "error: $SOL_ROOT/$pkg.opam not found -- is SOL_ROOT a Sol checkout?" >&2
    exit 1
  fi
  echo "  pinning $pkg"
  opam pin add -y --kind=path "$pkg" "$SOL_ROOT" >/dev/null
done

# The framework's not-yet-published dependencies are declared in the packages'
# own `pin-depends` (see the hand-written .opam files), so they resolve here
# without this script knowing anything about them. That is the point: dependency
# knowledge belongs to the package that declares the dependency, not to the
# bootstrap, the workspace, or a generated Dockerfile.
echo "  installing framework (this compiles it into the switch)"
opam install -y sol-svc sol-worker sol-fn sol-jobs

echo
echo "Done. The framework is installed into the current opam switch:"
echo "  $(opam var prefix 2>/dev/null || echo '<switch>')"
echo
echo "Run the suite with:  eval \$(opam env) && dune runtest"
