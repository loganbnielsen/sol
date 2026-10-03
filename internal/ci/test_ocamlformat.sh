#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/scratch_repo.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_ocamlformat.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
scratch_repo_init .
git -c user.email=t@example.invalid -c user.name=test commit -q --allow-empty -m init
cp "$ROOT/.ocamlformat" .

preview_bin="$tmp/preview-bin"
mkdir -p "$preview_bin"
for tool in bash cat git grep; do
  ln -s "$(command -v "$tool")" "$preview_bin/$tool"
done
preview="$tmp/preview.txt"
filler="yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy"
big_preview() {
  {
    printf '%s\n' "$1"
    for i in $(seq 1 4000); do
      printf 'filler line %s %s\n' "$i" "$filler"
    done
    [ "$#" -lt 2 ] || printf '%s\n' "$2"
  } >"$preview"
}
stub_opam() {
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$preview" >"$preview_bin/opam"
  chmod +x "$preview_bin/opam"
}
run_preview() {
  env PATH="$preview_bin" "$CHECK" --all >"$tmp/preview.out" 2>&1
}

fail_preview() {
  echo "  [FAIL] $1" >&2
  sed -n '1,12p' "$tmp/preview.out" | sed 's/^/         /' >&2
  exit 1
}

stub_opam
big_preview 'no drift in this preview'
run_preview || fail_preview "a clean preview was refused"
echo "  [OK]   a clean preview of $(wc -c <"$preview") bytes passes"

big_preview 'filler' 'Promoting platform/shared/templates/workspace/events/charged.ml'
run_preview && fail_preview "a promotion reported at the end of a large preview was accepted"
echo "  [OK]   a promotion reported anywhere in a large preview is refused"

big_preview 'Promoting .ocamlformat'
run_preview && fail_preview "a promotion on the first line of a large preview was accepted"
echo "  [OK]   a promotion on the first line of a large preview is refused"

big_preview 'platform/shared/templates/workspace/events/charged.ml'
run_preview && fail_preview "a large preview naming the exempt path was accepted"
case "$(cat "$tmp/preview.out")" in
  *"which the staged check exempts"*) echo "  [OK]   the exempt path in a large preview is refused, by name" ;;
  *) fail_preview "the exempt-path refusal does not name the exemption" ;;
esac

printf '#!/usr/bin/env bash\necho "dune: unknown rule @fmt" >&2\nexit 1\n' >"$preview_bin/opam"
chmod +x "$preview_bin/opam"
run_preview && fail_preview "a preview that could not be produced was accepted"
case "$(cat "$tmp/preview.out")" in
  *"could not run"*) echo "  [OK]   a dune fmt that cannot run is refused, by name" ;;
  *) fail_preview "the refusal does not say the preview could not run" ;;
esac

if ! command -v ocamlformat >/dev/null 2>&1; then
  echo "  (ocamlformat not installed — skipping the --staged half of the ocamlformat guard mutation test)"
  echo "ocamlformat guard: the --all preview expectations hold."
  exit 0
fi

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

mkdir -p platform/shared/templates/workspace/events
printf 'let h  z   =   z\n' > platform/shared/templates/workspace/events/charged.ml
git add unformatted.ml platform/shared/templates/workspace/events/charged.ml
out="$("$CHECK" --staged 2>&1)" && {
  echo "  [FAIL] the template exemption let an unformatted staged file through" >&2
  exit 1
}
case "$out" in
  *charged.ml*) echo "  [FAIL] the exempt scaffold template was named: $out" >&2; exit 1 ;;
  *unformatted.ml*) echo "  [OK]   a scaffold template is exempt while other files are still checked" ;;
  *) echo "  [FAIL] refusal did not name the checked file: $out" >&2; exit 1 ;;
esac
git restore --staged unformatted.ml platform/shared/templates/workspace/events/charged.ml

if "$CHECK" --nonsense >/dev/null 2>&1; then
  echo "  [FAIL] an unknown mode should not pass" >&2
  exit 1
fi
echo "  [OK]   an unknown mode does not pass"

echo "ocamlformat guard: all expectations hold."
