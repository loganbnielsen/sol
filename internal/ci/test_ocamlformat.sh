#!/usr/bin/env bash
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
git -c user.email=t@example.invalid -c user.name=test commit -q --allow-empty -m init
cp "$ROOT/.ocamlformat" .

printf 'let f x = x + 1\n' > formatted.ml
ocamlformat --inplace formatted.ml
printf 'let g  y   =   y\n' > unformatted.ml
printf 'not ocaml\n' > notes.txt

git add notes.txt
if ! "$CHECK" --staged >/dev/null 2>&1; then
  echo "  [FAIL] no staged OCaml should pass" >&2
  exit 1
fi
echo "  [OK]   no staged OCaml passes"

git add formatted.ml
if ! "$CHECK" --staged >/dev/null 2>&1; then
  echo "  [FAIL] a formatted staged file should pass" >&2
  exit 1
fi
echo "  [OK]   a formatted staged file passes"

git add unformatted.ml
out="$("$CHECK" --staged 2>&1)" && {
  echo "  [FAIL] an unformatted staged file was accepted" >&2
  exit 1
}
case "$out" in
  *unformatted.ml*) echo "  [OK]   an unformatted staged file is refused, named" ;;
  *) echo "  [FAIL] refusal did not name the file: $out" >&2; exit 1 ;;
esac

git restore --staged unformatted.ml
if ! "$CHECK" --staged >/dev/null 2>&1; then
  echo "  [FAIL] unstaging the unformatted file should restore a pass" >&2
  exit 1
fi
echo "  [OK]   the check is per file, not sticky"

if "$CHECK" --nonsense >/dev/null 2>&1; then
  echo "  [FAIL] an unknown mode should not pass" >&2
  exit 1
fi
echo "  [OK]   an unknown mode does not pass"

echo "ocamlformat guard: all expectations hold."
