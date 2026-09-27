#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
workflows="$root/.github/workflows"

if [ ! -d "$workflows" ]; then
  echo "check_workflow_paths: no workflow directory at $workflows" >&2
  exit 1
fi

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

invoked_scripts() {
  awk '
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/^-[[:space:]]*/, "", line)   # both `- run: cmd` and a `run: |` body line
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
  if grep -qE '(^|[^[:alnum:]_])rg[[:space:]]' "$root/$script" 2>/dev/null; then
    echo "check_workflow_paths: '$script' calls rg, which CI runners do not have" >&2
    echo "  use grep (rg is not part of the runner image)" >&2
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
echo "check_workflow_paths: $checked paths: filter entr(y/ies) checked, all naming something in the repository; $invoked directly invoked script(s) checked, all executable and none reaching for rg"
