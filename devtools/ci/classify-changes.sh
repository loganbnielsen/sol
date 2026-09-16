#!/usr/bin/env bash
# classify-changes.sh -- the single definition of "docs-only" for Sol.
#
# Both the local pre-commit hook and CI call this, so the two cannot drift
# into disagreeing about what counts as a bookkeeping change. It answers one
# question: is every changed path in the explicitly safe allowlist?
#
#   docs-only   every path is safe -> the expensive suite is not required
#   source      anything else, any mixed diff, or any inability to resolve
#               the requested range
#
# FAIL CLOSED. Uncertainty always resolves to `source`: an unclassifiable diff
# costs compute, never correctness. In particular:
#   - an empty change list is `source` (it also covers "the diff command
#     silently produced nothing because it failed")
#   - an unresolvable range is `source`
#   - an unknown argument is `source`
# This script therefore exits 0 in every case; the classification is data, not
# a status. Callers branch on the printed token.
#
# The allowlist, deliberately small and explicit:
#   docs/**                              documentation tree
#   pipeline/tickets/**                  pipeline bookkeeping
#   **/*.md  EXCEPT .github/**           markdown anywhere else
#   devtools/perf/perf_baseline.json     the perf baseline
#
# `.github/**` is source-like for CI classification REGARDLESS OF EXTENSION.
# A workflow or action edit can change the gate itself, so it must never ride
# along on a docs-only path -- and a .md file under .github buys us nothing
# worth the extra case to reason about.
#
# Usage:
#   classify-changes.sh --staged                 # staged paths (pre-commit)
#   classify-changes.sh --range A...B            # git diff --name-only A...B
#   classify-changes.sh --files-from FILE        # newline-separated paths

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

# `seen` guards the empty case: an empty (or whitespace-only) list must not
# fall through to the docs-only exit below.
seen=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  seen=1
  case "$p" in
    .github/*)
      # Checked first, and before the *.md rule, so .github/**/*.md is source.
      emit source ;;
    docs/*)                            continue ;;
    pipeline/tickets/*)                continue ;;
    devtools/perf/perf_baseline.json)  continue ;;
    *.md)                              continue ;;
    *)                                 emit source ;;
  esac
done <<EOF
$paths
EOF

[ "$seen" -eq 1 ] || emit source
emit docs-only
