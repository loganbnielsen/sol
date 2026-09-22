#!/usr/bin/env bash
# The one definition of "is this OCaml ocamlformat-clean?".
#
#   check_ocamlformat.sh --all      the whole project, exactly as CI runs it
#   check_ocamlformat.sh --staged   only the staged .ml/.mli files (pre-commit)
#
# Two modes rather than one because a pre-commit check must not be blocked by
# unrelated, unformatted work in progress elsewhere in the worktree — which is
# normal here, since each actor works in its own worktree with WIP in it. CI has
# a clean checkout, so it can afford the whole-project check.
#
# Staged mode checks each staged file's working-tree content. That is the content
# a developer is about to commit in the ordinary case; a file whose *staged* hunk
# is formatted while later uncommitted edits are not is the one case it reads
# differently, and it reads it in the direction that fails closed.
#
# Exit: 0 formatted, 1 would change (or CI could not check), 2 bad usage.
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
    # Fail closed: if the formatter or dune is unavailable this reports failure
    # rather than silently passing, because in CI that is a real problem.
    if ! preview="$(opam exec -- dune fmt --preview 2>&1)"; then
      echo "$preview" >&2
      report "the project (dune fmt --preview could not run)"
    fi
    # `dune fmt --preview` prints "Promoting <build path>.corrected to" and the
    # destination path on the next line, one per file. Echo its own output rather
    # than re-parsing it, so the developer sees the paths dune named.
    if printf '%s\n' "$preview" | grep -q '^Promoting '; then
      echo "$preview" >&2
      report "at least one file (listed above)"
    fi
    ;;
  --staged)
    cd "$ROOT" || exit 1
    if ! command -v ocamlformat >/dev/null 2>&1; then
      # A local convenience check, not the authoritative gate: CI always has the
      # pinned formatter, so a developer without it is told, not blocked.
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
