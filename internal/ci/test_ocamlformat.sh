#!/usr/bin/env bash
# Mutation test for internal/ci/check_ocamlformat.sh.
#
# The --staged mode is what the pre-commit hook calls, and its whole value is the
# refusal: if it accepts an unformatted file it is worse than absent, because the
# hook would then let the commit through and CI would fail on Format check
# instead — exactly the bounce it exists to prevent. So each expectation below is
# asserted in both directions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_ocamlformat.sh"

if ! command -v ocamlformat >/dev/null 2>&1; then
  echo "  (ocamlformat not installed — skipping the ocamlformat guard mutation test)"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q .
# An empty commit so HEAD exists: unstaging (`git restore --staged`) needs one.
git -c user.email=t@example.invalid -c user.name=test commit -q --allow-empty -m init
cp "$ROOT/.ocamlformat" .

# A file ocamlformat is happy with, and one it is not.
printf 'let f x = x + 1\n' > formatted.ml
ocamlformat --inplace formatted.ml
printf 'let g  y   =   y\n' > unformatted.ml
printf 'not ocaml\n' > notes.txt

# No staged OCaml at all: acceptable (a docs commit).
git add notes.txt
if ! "$CHECK" --staged >/dev/null 2>&1; then
  echo "  [FAIL] no staged OCaml should pass" >&2
  exit 1
fi
echo "  [OK]   no staged OCaml passes"

# A formatted file: acceptable.
git add formatted.ml
if ! "$CHECK" --staged >/dev/null 2>&1; then
  echo "  [FAIL] a formatted staged file should pass" >&2
  exit 1
fi
echo "  [OK]   a formatted staged file passes"

# An unformatted file: refused, and the message names the file and the fix.
git add unformatted.ml
out="$("$CHECK" --staged 2>&1)" && {
  echo "  [FAIL] an unformatted staged file was accepted" >&2
  exit 1
}
case "$out" in
  *unformatted.ml*) echo "  [OK]   an unformatted staged file is refused, named" ;;
  *) echo "  [FAIL] refusal did not name the file: $out" >&2; exit 1 ;;
esac

# The formatted file alone still passes once the bad one is unstaged: the check
# is per file, not sticky.
git restore --staged unformatted.ml
if ! "$CHECK" --staged >/dev/null 2>&1; then
  echo "  [FAIL] unstaging the unformatted file should restore a pass" >&2
  exit 1
fi
echo "  [OK]   the check is per file, not sticky"

# Bad usage is its own exit code, not a false pass.
if "$CHECK" --nonsense >/dev/null 2>&1; then
  echo "  [FAIL] an unknown mode should not pass" >&2
  exit 1
fi
echo "  [OK]   an unknown mode does not pass"

# --all is deliberately not asserted here: it checks the whole project, so run
# from this scratch repository it would have nothing to check. CI runs that mode
# directly on every non-docs change, which is its test.

echo "ocamlformat guard: all expectations hold."
