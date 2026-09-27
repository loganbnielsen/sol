#!/usr/bin/env bash

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

files="$(cd "$root" && find cli/lib cli/bin -type f \( -name '*.ml' -o -name '*.mli' \) \
  ! -name 'sol_cli_provider.ml' ! -name 'sol_cli_provider.mli' \
  ! -name 'sol_cli_provider_capabilities.ml' ! -name 'sol_cli_provider_capabilities.mli' \
  ! -name 'sol_cli_provider_registry.ml' ! -name 'sol_cli_provider_registry.mli' | sort)"

count_dispatch() {
  { grep -oE 'Sol_cli_provider\.(Aws|Gcp)\b|\b(Aws|Gcp)_outputs\b' "$root/$1" || true; } | wc -l | tr -d ' '
}

identity_declarations='^[[:space:]]*type[[:space:]]+(whoami_identity|credential_assumption)|^[[:space:]]*let[[:space:]]+(rec[[:space:]]+)?(whoami_identity_of_json|single_string_of_json|role_name_of_arn|normalize_role_arn|principal_role_name|principal_matches|refusal_is_deescalation)|^[[:space:]]*[{;]?[[:space:]]*canonical_arn[[:space:]]*:'

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
  awk -v k="$1" -v p="$2" '$1 == k && $2 == p { print $3; exit }' "$allowlist"
}

provider_name_literals="\"($(printf '%s\n' $providers | tr '\n' '|')azure)\""

count_provider_names() {
  { grep -oE "$provider_name_literals" "$root/$1" || true; } | wc -l | tr -d ' '
}

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
  if is_generic_file "$f"; then
    pn="$(count_provider_names "$f")"
    if [ "${pn:-0}" -gt 0 ]; then
      echo "check_provider_dispatch: $f spells a provider's name ($pn occurrence(s)) -- provider identity belongs in the provider tier (sol_cli_provider, its capabilities, or the provider's own module), not in generic Sol code." >&2
      fail=1
    fi
  fi
done

for f in $generic_files; do
  i="$(count_identity "$f")"
  if [ "${i:-0}" -gt 0 ]; then
    echo "check_provider_dispatch: $f declares provider-native identity machinery ($i declaration(s)) -- ARNs, the whoami identity record and the principal comparison belong with the provider that produces them (sol_cli_aws_cluster), not in generic Sol code." >&2
    fail=1
  fi
done

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
