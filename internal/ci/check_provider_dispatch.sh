#!/usr/bin/env bash
# REFAC-092: provider dispatch may only shrink, and no wildcard may stand in for a provider.
#
# Sol's cloud lifecycle knows AWS and GCP through pattern matches on
# `Sol_cli_provider.t` (and on the `Aws_outputs | Gcp_outputs` variant) spread across
# generic modules. The lifecycle simplification plan
# (internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md) moves that
# knowledge behind provider capabilities, one step at a time. This guard makes the
# migration a number:
#
#   1. Every file under cli/sol/{lib,bin} has an allowed count of provider-constructor
#      and output-variant occurrences (internal/ci/provider_dispatch_allowlist.txt).
#      More than allowed -> fail (new dispatch). Fewer -> fail too, asking for the
#      allowlist to be lowered, so the ratchet is recorded in the same PR.
#   2. A wildcard arm (`| _`) in a match whose other arms name a provider constructor
#      is a provider the match silently defaults. SEC-010 was exactly that:
#      `Aws -> true | _ -> false` never guarded GCP. New ones fail; the survivors are
#      allowlisted with a reason. A `| _` is attributed to a match by indentation (its
#      sibling arms share its column), so a nested option match next to provider arms
#      is not miscounted.
#
# Usage: check_provider_dispatch.sh [repo-root] [allowlist]

set -euo pipefail

root="${1:-.}"
allowlist="${2:-$root/internal/ci/provider_dispatch_allowlist.txt}"

if [ ! -d "$root/cli/sol/lib" ]; then
  echo "check_provider_dispatch: no cli/sol/lib under '$root'." >&2
  exit 1
fi
if [ ! -f "$allowlist" ]; then
  echo "check_provider_dispatch: allowlist '$allowlist' not found." >&2
  exit 1
fi

# The provider module defines the constructors, and the registry selects a
# provider's implementation by them: its table-shaped capabilities (REFAC-095) and
# its cluster (REFAC-096, one layer up because the cluster modules depend on the
# lifecycle). Those are the places provider selection belongs.
files="$(cd "$root" && find cli/sol/lib cli/sol/bin -type f \( -name '*.ml' -o -name '*.mli' \) \
  ! -name 'sol_cli_provider.ml' ! -name 'sol_cli_provider.mli' \
  ! -name 'sol_cli_provider_capabilities.ml' ! -name 'sol_cli_provider_capabilities.mli' \
  ! -name 'sol_cli_provider_clusters.ml' ! -name 'sol_cli_provider_clusters.mli' | sort)"

count_dispatch() {
  { grep -oE 'Sol_cli_provider\.(Aws|Gcp)\b|\b(Aws|Gcp)_outputs\b' "$root/$1" || true; } | wc -l | tr -d ' '
}

count_wildcards() {
  awk '
    function indent(s,    m) { match(s, /^[ \t]*/); return RLENGTH }
    { line[NR] = $0 }
    END {
      n = 0
      for (i = 1; i <= NR; i++) {
        if (line[i] !~ /^[ \t]*\|[ \t]*_([ \t]|$)/) continue
        col = indent(line[i])
        provider = 0
        for (j = i - 1; j >= 1; j--) {
          s = line[j]
          if (s ~ /^[ \t]*$/) continue
          c = indent(s)
          if (c > col) continue
          if (c == col && s ~ /^[ \t]*\|/) {
            if (s ~ /^[ \t]*\|[ \t]*\(?Sol_cli_provider\.(Aws|Gcp)/) provider = 1
            continue
          }
          break
        }
        if (provider) n++
      }
      print n
    }' "$root/$1"
}

allowed() {
  # allowed <kind> <path>  -> the count, or empty when the file is not listed
  awk -v k="$1" -v p="$2" '$1 == k && $2 == p { print $3; exit }' "$allowlist"
}

fail=0
total=0
wild_total=0
for f in $files; do
  n="$(count_dispatch "$f")"
  w="$(count_wildcards "$f")"
  total=$((total + n))
  wild_total=$((wild_total + w))
  a="$(allowed dispatch "$f")"
  aw="$(allowed wildcard "$f")"
  a="${a:-0}"
  aw="${aw:-0}"
  if [ "$n" -gt "$a" ]; then
    echo "check_provider_dispatch: $f has $n provider-dispatch occurrence(s), $a allowed -- new provider knowledge in a generic module; put it behind a provider capability instead." >&2
    fail=1
  elif [ "$n" -lt "$a" ]; then
    echo "check_provider_dispatch: $f has $n provider-dispatch occurrence(s), $a allowed -- lower its entry in $(basename "$allowlist") to record the reduction." >&2
    fail=1
  fi
  if [ "$w" -gt "$aw" ]; then
    echo "check_provider_dispatch: $f has $w wildcard arm(s) in a provider match, $aw allowed -- a new provider would silently take the default (SEC-010); name every provider." >&2
    fail=1
  elif [ "$w" -lt "$aw" ]; then
    echo "check_provider_dispatch: $f has $w wildcard provider arm(s), $aw allowed -- lower its entry in $(basename "$allowlist")." >&2
    fail=1
  fi
done

# An allowlist entry for a file that no longer exists is a stale ratchet.
while read -r kind path _; do
  case "$kind" in dispatch | wildcard) ;; *) continue ;; esac
  if [ ! -f "$root/$path" ]; then
    echo "check_provider_dispatch: allowlist names $path, which no longer exists -- remove the entry." >&2
    fail=1
  fi
done <"$allowlist"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "check_provider_dispatch: $total provider-dispatch occurrence(s) and $wild_total wildcard provider arm(s) outside sol_cli_provider and its registry, each within its allowlist."
