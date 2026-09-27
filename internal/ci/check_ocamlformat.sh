#!/usr/bin/env bash
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
MODE="${1:---all}"

report() {
  echo "" >&2
  echo "✗ ocamlformat would change: $*" >&2
  echo "  Fix: dune fmt && git add -u" >&2
  exit 1
}

case "$MODE" in
  --all)
    cd "$ROOT" || exit 1
    if ! preview="$(opam exec -- dune fmt --preview 2>&1)"; then
      echo "$preview" >&2
      report "the project (dune fmt --preview could not run)"
    fi
    if printf '%s\n' "$preview" | grep -q '^Promoting '; then
      echo "$preview" >&2
      report "at least one file (listed above)"
    fi
    ;;
  --staged)
    cd "$ROOT" || exit 1
    if ! command -v ocamlformat >/dev/null 2>&1; then
      echo "  (ocamlformat not installed — staged format check skipped; CI still checks it)"
      exit 0
    fi
    files="$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.(ml|mli)$' || true)"
    [ -z "$files" ] && exit 0
    bad=""
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      ocamlformat --check "$f" >/dev/null 2>&1 || bad="$bad $f"
    done <<< "$files"
    [ -n "$bad" ] && report "$bad"
    ;;
  *)
    echo "usage: $0 [--all|--staged]" >&2
    exit 2
    ;;
esac

exit 0
