#!/usr/bin/env bash
# Mutation test for check_provider_dispatch.sh (REFAC-092). A guard that cannot fail is
# decoration: feed it each defect it exists for and assert it refuses, then the clean shape
# and assert it accepts.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
guard="$root/internal/ci/check_provider_dispatch.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0

# mkcase <name> <allowlist> ; files are then written with put
mkcase() {
  mkdir -p "$tmp/$1/cli/sol/lib" "$tmp/$1/cli/sol/bin"
  printf '%s\n' "$2" >"$tmp/$1/allow.txt"
}
put() { printf '%s\n' "$3" >"$tmp/$1/cli/sol/$2"; }
expect_reject() {
  if "$guard" "$tmp/$1" "$tmp/$1/allow.txt" >/dev/null 2>&1; then
    echo "test_provider_dispatch_check: guard ACCEPTED $2." >&2
    fail=1
  fi
}
expect_accept() {
  if ! "$guard" "$tmp/$1" "$tmp/$1/allow.txt" >/dev/null 2>&1; then
    echo "test_provider_dispatch_check: guard REJECTED $2." >&2
    "$guard" "$tmp/$1" "$tmp/$1/allow.txt" >&2 || true
    fail=1
  fi
}

exhaustive='let f = function
  | Sol_cli_provider.Aws -> 1
  | Sol_cli_provider.Gcp -> 2
;;'

# 1. The allowlisted baseline is accepted.
mkcase base 'dispatch cli/sol/lib/a.ml 2'
put base lib/a.ml "$exhaustive"
expect_accept base "an exhaustive match within its allowlist"

# 2. A provider match in a module the allowlist does not name is new dispatch.
mkcase newfile 'dispatch cli/sol/lib/a.ml 2'
put newfile lib/a.ml "$exhaustive"
put newfile bin/b.ml "$exhaustive"
expect_reject newfile "a provider match in a new module"

# 3. Growth inside an allowlisted module.
mkcase grow 'dispatch cli/sol/lib/a.ml 2'
put grow lib/a.ml "$exhaustive
let g = function
  | Sol_cli_provider.Aws -> true
  | Sol_cli_provider.Gcp -> false
;;"
expect_reject grow "growth past the allowed count"

# 4. A reduction the allowlist does not record (the ratchet must be written down).
mkcase shrink 'dispatch cli/sol/lib/a.ml 4'
put shrink lib/a.ml "$exhaustive"
expect_reject shrink "a reduction without lowering the allowlist"

# 5. The SEC-010 shape: a wildcard standing in for every other provider.
mkcase wild 'dispatch cli/sol/lib/a.ml 1'
put wild lib/a.ml 'let creates_postgres = function
  | Sol_cli_provider.Aws -> true
  | _ -> false
;;'
expect_reject wild "a wildcard arm in a provider match"

# 6. ...accepted only when allowlisted.
mkcase wildok 'dispatch cli/sol/lib/a.ml 1
wildcard cli/sol/lib/a.ml 1 reason'
put wildok lib/a.ml 'let creates_postgres = function
  | Sol_cli_provider.Aws -> true
  | _ -> false
;;'
expect_accept wildok "an allowlisted wildcard provider arm"

# 7. A wildcard in a *different* match next to provider arms is not a provider wildcard
#    (the backend-config shape: an option match wrapping a provider match).
mkcase nested 'dispatch cli/sol/lib/a.ml 2'
put nested lib/a.ml 'let backend b p =
  match b with
  | Some bucket ->
    (match p with
     | Sol_cli_provider.Aws -> Ok bucket
     | Sol_cli_provider.Gcp -> Ok bucket)
  | _ -> Error "no bucket"
;;'
expect_accept nested "a wildcard that belongs to an enclosing non-provider match"

# 8. A stale allowlist entry for a deleted module.
mkcase stale 'dispatch cli/sol/lib/a.ml 2
dispatch cli/sol/lib/gone.ml 3'
put stale lib/a.ml "$exhaustive"
expect_reject stale "an allowlist entry for a module that no longer exists"

# 9. The provider module itself is exempt: it defines the constructors.
mkcase provider 'dispatch cli/sol/lib/a.ml 2'
put provider lib/a.ml "$exhaustive"
put provider lib/sol_cli_provider.ml 'type t = Aws | Gcp
let to_string = function Aws -> "aws" | Gcp -> "gcp"'
expect_accept provider "the provider module's own constructors"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "test_provider_dispatch_check: guard rejects new dispatch, growth, unrecorded reductions, wildcard provider arms and stale entries; accepts the baseline, allowlisted wildcards, nested non-provider wildcards and the provider module."
