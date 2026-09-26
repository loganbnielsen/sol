#!/usr/bin/env bash
# REFAC-099: every entry in a workflow's `paths:` filter must still name something
# in the repository.
#
# A `run:` step that names a moved file fails loudly. A `paths:` filter that names
# one does not: the workflow simply stops triggering, and a guard that never runs
# reads exactly like a guard that passes. This check turns that silent failure into
# a loud one.
#
# What "exists" means:
#   - a literal entry (no `*`, `?` or `[`) must exist as a file or directory;
#   - a glob entry must have its literal prefix -- the path up to the last `/`
#     before the first glob character -- exist as a directory, and at least one
#     tracked file must match it (`git ls-files -- ':(glob)<entry>'`).
# A negated entry (`!pattern`) is exempt: excluding nothing is harmless.
#
# The same silence has a second shape, learned the hard way: a `run:` step that invokes a
# repository script *directly* (`internal/ci/foo.sh`, not `bash internal/ci/foo.sh`) gets exit
# code 126 if the file is not executable, and a local sweep that calls everything as
# `bash <script>` cannot see it. So a script the workflow invokes as a command must carry the
# executable bit.
#
# Usage: check_workflow_paths.sh [repo-root]
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
workflows="$root/.github/workflows"

if [ ! -d "$workflows" ]; then
  echo "check_workflow_paths: no workflow directory at $workflows" >&2
  exit 1
fi

# Print "<file>\t<line>\t<entry>" for every item of every `paths:` list. A list
# ends at the first line that is not an item or blank.
entries() {
  awk '
    FNR == 1 { in_paths = 0 }
    /^[[:space:]]*paths:[[:space:]]*$/ { in_paths = 1; next }
    in_paths && /^[[:space:]]*-[[:space:]]/ {
      item = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", item)
      sub(/[[:space:]]+#.*$/, "", item)
      gsub(/^["\047]|["\047]$/, "", item)
      printf "%s\t%d\t%s\n", FILENAME, FNR, item
      next
    }
    in_paths && /^[[:space:]]*$/ { next }
    { in_paths = 0 }
  ' "$workflows"/*.yml "$workflows"/*.yaml 2>/dev/null
}

# Print the repository shell scripts a workflow invokes as a command: the first token of a
# `run:` line (or of a line inside a multi-line `run:` body) that is a path under internal/ or
# cli/platform/local/scripts/. `bash <script>` is deliberately not matched -- the bit is
# irrelevant there -- and neither is a `paths:` entry.
invoked_scripts() {
  awk '
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/^run:[[:space:]]*/, "", line)
      split(line, parts, /[[:space:]]+/)
      if (parts[1] ~ /^(internal|cli\/platform\/local\/scripts)\/[A-Za-z0-9_\/.-]*\.sh$/) print parts[1]
    }
  ' "$workflows"/*.yml "$workflows"/*.yaml 2>/dev/null | sort -u
}

checked=0
invoked=0
fail=0
while IFS= read -r script; do
  [ -n "$script" ] || continue
  invoked=$((invoked + 1))
  if [ ! -x "$root/$script" ]; then
    echo "check_workflow_paths: the workflow runs '$script', which is not executable" >&2
    echo "  a direct invocation exits 126; make it executable, or invoke it as 'bash $script'" >&2
    fail=1
  fi
done < <(invoked_scripts)

while IFS=$'\t' read -r file line entry; do
  [ -n "$entry" ] || continue
  case "$entry" in '!'*) continue ;; esac
  checked=$((checked + 1))
  where="${file#"$root"/}:$line"
  case "$entry" in
    *'*'* | *'?'* | *'['*)
      prefix="${entry%%[\*\?\[]*}"
      prefix_dir="${prefix%/*}"
      [ "$prefix_dir" = "$prefix" ] && prefix_dir="."
      if [ ! -d "$root/$prefix_dir" ]; then
        echo "check_workflow_paths: $where: '$entry' -- its directory '$prefix_dir' does not exist" >&2
        fail=1
      elif [ -z "$(git -C "$root" ls-files -- ":(glob)$entry" | head -1)" ]; then
        echo "check_workflow_paths: $where: '$entry' matches no tracked file" >&2
        fail=1
      fi
      ;;
    *)
      if [ ! -e "$root/$entry" ]; then
        echo "check_workflow_paths: $where: '$entry' does not exist" >&2
        fail=1
      fi
      ;;
  esac
done < <(entries)

if [ "$fail" -ne 0 ]; then
  echo "check_workflow_paths: a paths: filter names something that is gone, so its workflow would silently stop triggering" >&2
  exit 1
fi
echo "check_workflow_paths: $checked paths: filter entr(y/ies) checked, all naming something in the repository; $invoked directly invoked script(s) checked, all executable"
