#!/usr/bin/env bash

set -uo pipefail

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

MODE=""
RANGE=""
FILES_FROM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --staged)     MODE=staged; shift ;;
    --range)      MODE=range; RANGE="${2:-}"; shift 2 ;;
    --files-from) MODE=files; FILES_FROM="${2:-}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "classify-changes: unknown argument: $1" >&2; echo source; exit 0 ;;
  esac
done

emit() { printf '%s\n' "$1"; exit 0; }

if [ -z "$MODE" ]; then
  echo "classify-changes: no mode given (see --help)" >&2
  emit source
fi

case "$MODE" in
  staged)
    [ -n "$(git rev-parse --git-dir 2>/dev/null)" ] || emit source
    paths="$(git diff --cached --name-only 2>/dev/null)" || emit source
    ;;
  range)
    [ -n "$RANGE" ] || emit source
    paths="$(git -c core.quotepath=false diff --name-only "$RANGE" 2>/dev/null)" || emit source
    ;;
  files)
    [ -n "$FILES_FROM" ] || emit source
    [ -r "$FILES_FROM" ] || emit source
    paths="$(cat "$FILES_FROM" 2>/dev/null)" || emit source
    ;;
esac

seen=0
generated_artifacts="docs/reference/cli.md"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  seen=1
  case "$p" in
    .github/*)
      emit source ;;
    docs/*)
      for generated in $generated_artifacts; do
        [ "$p" = "$generated" ] && emit source
      done
      continue
      ;;
    internal/pipeline/tickets/*)                continue ;;
    internal/tooling/perf/perf_baseline.json)  continue ;;
    *.md)                              continue ;;
    *)                                 emit source ;;
  esac
done <<EOF
$paths
EOF

[ "$seen" -eq 1 ] || emit source
emit docs-only
