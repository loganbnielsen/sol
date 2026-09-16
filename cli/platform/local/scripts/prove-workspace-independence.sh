#!/usr/bin/env bash
# Prove a Sol workspace survives without the repository that created it
# (DEC-024 / DEC-025 / FEAT-085).
#
# This is the third and strongest boundary test:
#
#   normal tests            -> does the code work?
#   fresh CI bootstrap      -> can Sol establish its package boundary from scratch?
#   this                    -> can an application survive without the repository
#                              that created it?
#
# It is deliberately hostile: the workspace is COPIED (never referenced in place),
# the build runs in a FRESH opam switch, and the run FAILS if any dependency pin
# resolves back into the Sol checkout. Without that last assertion the proof can
# pass for the wrong reason -- which it nearly did by hand: `opam env --switch=X`
# without `--set-switch` does not switch, so an "isolated" inspection silently read
# the developer's default switch.
#
# Usage:
#   bash cli/platform/local/scripts/prove-workspace-independence.sh [workspace-dir]
#     workspace-dir  defaults to examples/pluto
#
# Exits non-zero on the first violated invariant, naming it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WS_SRC="${1:-examples/pluto}"
WS_ABS="$REPO_ROOT/$WS_SRC"
PROOF_ROOT="${PROOF_ROOT:-/tmp/sol-proof}"
WS_NAME="$(basename "$WS_SRC")"
COPY="$PROOF_ROOT/$WS_NAME"
SWITCH="${PROOF_SWITCH:-sol-workspace-proof}"
FAILED=0

say()  { printf '\n=== %s\n' "$*"; }
fail() { printf '  FAIL: %s\n' "$*"; FAILED=1; }
pass() { printf '  ok:   %s\n' "$*"; }

expect_zero() { # <count> <description>
  if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2 (found $1)"; fi
}

[ -d "$WS_ABS" ] || { echo "error: $WS_ABS is not a directory" >&2; exit 2; }
[ -f "$WS_ABS/sol.yml" ] || { echo "error: $WS_ABS has no sol.yml -- not a Sol workspace" >&2; exit 2; }

# ── 1. Copy the workspace. Files only; never reference it in place. ───────────
say "Copying $WS_SRC (files only, no build output, no installed deps)"
rm -rf "$COPY"
mkdir -p "$COPY"
tar -c \
  --exclude=node_modules --exclude=_build --exclude=.git --exclude='*.docker-ctx' --exclude=dist \
  -C "$WS_ABS" . | tar -x -C "$COPY"

# ── 2. Static invariants: nothing in the copy reaches back out. ──────────────
say "Static invariants"

expect_zero "$(find "$COPY" -type l | wc -l | tr -d ' ')" \
  "no symlinks (a symlink is how the old vendor/framework coupling started)"

expect_zero "$(grep -rl "$REPO_ROOT" "$COPY" 2>/dev/null | wc -l | tr -d ' ')" \
  "no file mentions the Sol checkout path"

expect_zero "$(grep -rl -e 'SOL_HOME' -e 'vendor/framework' "$COPY" 2>/dev/null | wc -l | tr -d ' ')" \
  "no \$SOL_HOME / vendor/framework references"

# Build/install metadata must not escape the workspace. Deployment configuration
# is checked separately (BUG-035) because a user may legitimately point a target
# at a path they configured themselves.
expect_zero "$(grep -rn -e '\.\./\.\./' --include=dune --include='dune-project' --include='*.opam' "$COPY" 2>/dev/null | wc -l | tr -d ' ')" \
  "no ../ escapes in dune/opam metadata"

# ── 3. Fresh switch, and prove it is actually fresh. ─────────────────────────
say "Fresh opam switch: $SWITCH"
CREATED_SWITCH=0
if opam switch list --short 2>/dev/null | grep -qx "$SWITCH"; then
  echo "  (reusing existing proof switch; delete it with: opam switch remove $SWITCH)"
  echo "  NOTE: a reused switch is not a fresh proof -- CI always starts clean."
else
  opam switch create "$SWITCH" ocaml-base-compiler.5.4.1 -y
  CREATED_SWITCH=1
fi
# Deliberately NOT `opam env --set-switch`: that writes GLOBAL state, changing the
# user's default switch for every future shell. (It did exactly that to a developer
# machine while this script was being written.) Exporting OPAMSWITCH scopes the
# switch to this process, and the check below proves it actually took effect --
# without that check, opam silently targets the previous switch and the whole
# proof can read the wrong environment and pass for the wrong reason.
export OPAMSWITCH="$SWITCH"
eval "$(opam env --switch="$SWITCH" 2>/dev/null || true)"
[ "$(opam switch show)" = "$SWITCH" ] || { echo "error: not in switch $SWITCH (got $(opam switch show))" >&2; exit 2; }

if [ "$CREATED_SWITCH" -eq 1 ]; then
  say "Pins before dependency setup (a freshly created switch must have none)"
  expect_zero "$(opam pin list 2>/dev/null | wc -l | tr -d ' ')" "no pins before setup"
else
  say "Pins before dependency setup (switch reused -- not asserted)"
  opam pin list 2>/dev/null | sed 's/^/    /' || true
fi

# ── 4. Resolve and build the copied workspace. ───────────────────────────────
say "Resolving the workspace's declared dependencies"
( cd "$COPY" && opam install . --deps-only -y )

say "Pins afterwards (none may resolve into the original checkout)"
opam pin list 2>/dev/null | sed 's/^/    /' || true
expect_zero "$(opam pin list 2>/dev/null | grep -c "$REPO_ROOT" || true)" \
  "no pin resolves into $REPO_ROOT"

say "Building the copied workspace"
( cd "$COPY" && dune build )
pass "dune build succeeded in the copy"

# ── 5. Verdict ───────────────────────────────────────────────────────────────
say "Verdict"
if [ "$FAILED" -eq 0 ]; then
  echo "  PASS — $WS_SRC builds with no dependency on the repository that created it."
  echo "  Copy:   $COPY"
  echo "  Switch: $SWITCH"
else
  echo "  FAIL — see the violations above."
  exit 1
fi
