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
#   1. Every file under cli/{lib,bin} has an allowed count of provider-constructor
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

if [ ! -d "$root/cli/lib" ]; then
  echo "check_provider_dispatch: no cli/lib under '$root'." >&2
  exit 1
fi
if [ ! -f "$allowlist" ]; then
  echo "check_provider_dispatch: allowlist '$allowlist' not found." >&2
  exit 1
fi

# The provider module defines the constructors, and the registry selects a
# provider's implementation by them: its table-shaped capabilities (REFAC-095) and
# its cluster and its destruction steps (REFAC-096/097, one layer up because
# those modules depend on the lifecycle). Those are the places provider selection belongs.
files="$(cd "$root" && find cli/lib cli/bin -type f \( -name '*.ml' -o -name '*.mli' \) \
  ! -name 'sol_cli_provider.ml' ! -name 'sol_cli_provider.mli' \
  ! -name 'sol_cli_provider_capabilities.ml' ! -name 'sol_cli_provider_capabilities.mli' \
  ! -name 'sol_cli_provider_registry.ml' ! -name 'sol_cli_provider_registry.mli' | sort)"

count_dispatch() {
  { grep -oE 'Sol_cli_provider\.(Aws|Gcp)\b|\b(Aws|Gcp)_outputs\b' "$root/$1" || true; } | wc -l | tr -d ' '
}

# AUDIT-POST-001. The count above sees provider *constructors*, so the ARN parser and the
# whoami identity record that used to live in Sol_cli_cloud_lifecycle were invisible to it:
# they are provider-native identity, and they carry no constructor to count. This is the
# same boundary one level down, so it gets a rule of its own.
#
# It is deliberately a list of declarations rather than a spelling heuristic, because a
# heuristic cannot tell a declaration from prose -- "warn" contains "arn", and a comment
# may legitimately explain the mechanism it points at -- whereas the regression this
# prevents is exactly one family of names reappearing in a generic module. A provider
# implementation (sol_cli_aws_*, sol_cli_gcp_*) may declare all of them; those files are
# not in $generic_files.
identity_declarations='^[[:space:]]*type[[:space:]]+(whoami_identity|credential_assumption)|^[[:space:]]*let[[:space:]]+(rec[[:space:]]+)?(whoami_identity_of_json|single_string_of_json|role_name_of_arn|normalize_role_arn|principal_role_name|principal_matches|refusal_is_deescalation)|^[[:space:]]*[{;]?[[:space:]]*canonical_arn[[:space:]]*:'

# Which of those are *provider implementations* is read from the provider list, as
# check_destroy_completeness.sh reads its target roots (HARDEN-005), rather than written out
# here: a provider added later must be admitted without anyone remembering to edit this
# guard, and a provider list that cannot be read is a refusal rather than an empty one.
provider_module="$root/cli/lib/base/sol_cli_provider.ml"
providers="$(sed -n '/^let to_string/,/^;;/p' "$provider_module" 2>/dev/null | grep -oE '"[a-z0-9-]+"' | tr -d '"')"
if [ -z "$providers" ]; then
  echo "check_provider_dispatch: could not read the provider list from $provider_module -- refusing to decide the boundary from an empty list." >&2
  exit 1
fi
provider_impl="$(printf '%s\n' $providers | sed 's/^/sol_cli_/; s/$/_/' | paste -sd'|' -)"
generic_files="$(printf '%s\n' $files | grep -vE "/($provider_impl)" || true)"

count_identity() {
  { grep -cE "$identity_declarations" "$root/$1" || true; } | tr -d ' '
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

# AUDIT-POST-003. Provider identity *spelled as a string* was invisible to the count above:
# (The pattern below is built from the provider list plus the names of providers this
# repository deliberately does not have yet: writing one of those into a generic module is
# the same leak, and catching it before the provider exists is cheaper than after.)
# `Target_provider_owned (s, "aws")` in the config parser is provider knowledge with no
# constructor to count, and it passed the guard. That instance is gone -- the mapping is now
# data in the provider tier (Sol_cli_provider.owned_legacy_keys) -- so this is zero-tolerance
# rather than a ratchet: zero today, and a ratchet would only record how much came back. A
# provider implementation may spell its own name; it is skipped below.
provider_name_literals="\"($(printf '%s\n' $providers | tr '\n' '|')azure)\""

count_provider_names() {
  { grep -oE "$provider_name_literals" "$root/$1" || true; } | wc -l | tr -d ' '
}

# Membership is a loop, not a `case` on a joined string: a joined string built with an
# unquoted `printf '%s'` loses its separators and then matches nothing, which is a guard that
# silently checks nothing.
is_generic_file() {
  for g in $generic_files; do
    if [ "$g" = "$1" ]; then return 0; fi
  done
  return 1
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
  # AUDIT-POST-003: a provider's name spelled as a string is provider identity with no
  # constructor to count. The generic set is the same one the identity rule uses, derived
  # from the provider list, so a provider added later is exempt without editing this guard.
  if is_generic_file "$f"; then
    pn="$(count_provider_names "$f")"
    if [ "${pn:-0}" -gt 0 ]; then
      echo "check_provider_dispatch: $f spells a provider's name ($pn occurrence(s)) -- provider identity belongs in the provider tier (sol_cli_provider, its capabilities, or the provider's own module), not in generic Sol code." >&2
      fail=1
    fi
  fi
done

# AUDIT-POST-001: no generic module declares provider-native identity machinery. Zero
# tolerance, because the count is zero today and a ratchet here would only record how much
# of it came back.
for f in $generic_files; do
  i="$(count_identity "$f")"
  if [ "${i:-0}" -gt 0 ]; then
    echo "check_provider_dispatch: $f declares provider-native identity machinery ($i declaration(s)) -- ARNs, the whoami identity record and the principal comparison belong with the provider that produces them (sol_cli_aws_cluster), not in generic Sol code." >&2
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
echo "check_provider_dispatch: $total provider-dispatch occurrence(s) and $wild_total wildcard provider arm(s) outside sol_cli_provider and its registry, each within its allowlist, and no provider-native identity declaration or provider name spelled as a string in a generic module."
