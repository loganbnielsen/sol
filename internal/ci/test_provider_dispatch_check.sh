#!/usr/bin/env bash

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
guard="$root/internal/ci/check_provider_dispatch.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0

repo="$(cd "$(dirname "$0")/../.." && pwd)"

mkcase() {
  mkdir -p "$tmp/$1/cli/lib/base" "$tmp/$1/cli/bin"
  printf '%s\n' "$2" >"$tmp/$1/allow.txt"
  cp "$repo/cli/lib/base/sol_cli_provider.ml" "$tmp/$1/cli/lib/base/"
}
put() { printf '%s\n' "$3" >"$tmp/$1/cli/$2"; }
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

mkcase base 'dispatch cli/lib/a.ml 2'
put base lib/a.ml "$exhaustive"
expect_accept base "an exhaustive match within its allowlist"

mkcase newfile 'dispatch cli/lib/a.ml 2'
put newfile lib/a.ml "$exhaustive"
put newfile bin/b.ml "$exhaustive"
expect_reject newfile "a provider match in a new module"

mkcase grow 'dispatch cli/lib/a.ml 2'
put grow lib/a.ml "$exhaustive
let g = function
  | Sol_cli_provider.Aws -> true
  | Sol_cli_provider.Gcp -> false
;;"
expect_reject grow "growth past the allowed count"

mkcase shrink 'dispatch cli/lib/a.ml 4'
put shrink lib/a.ml "$exhaustive"
expect_reject shrink "a reduction without lowering the allowlist"

mkcase wild 'dispatch cli/lib/a.ml 1'
put wild lib/a.ml 'let creates_postgres = function
  | Sol_cli_provider.Aws -> true
  | _ -> false
;;'
expect_reject wild "a wildcard arm in a provider match"

mkcase wildok 'dispatch cli/lib/a.ml 1
wildcard cli/lib/a.ml 1 reason'
put wildok lib/a.ml 'let creates_postgres = function
  | Sol_cli_provider.Aws -> true
  | _ -> false
;;'
expect_accept wildok "an allowlisted wildcard provider arm"

mkcase nested 'dispatch cli/lib/a.ml 2'
put nested lib/a.ml 'let backend b p =
  match b with
  | Some bucket ->
    (match p with
     | Sol_cli_provider.Aws -> Ok bucket
     | Sol_cli_provider.Gcp -> Ok bucket)
  | _ -> Error "no bucket"
;;'
expect_accept nested "a wildcard that belongs to an enclosing non-provider match"

mkcase name ''
put name lib/a.ml 'let provider_of_key = function
  | "state_lock_table" -> Some "aws"
  | "tenant" -> Some "azure"
  | _ -> None
;;'
expect_reject name "a provider name spelled as a string in a generic module"

mkcase nameok ''
put nameok lib/sol_cli_aws_destruction.ml 'let argv = [ "aws"; "sts"; "get-caller-identity" ]'
expect_accept nameok "a provider name inside the provider's own implementation"

mkcase namemulti ''
put namemulti lib/a.ml 'let ok = 1'
put namemulti lib/b.ml 'let provider = "aws"'
expect_reject namemulti "a provider name in a second generic module"

mkcase namethird ''
printf 'let to_string = function\n  | Aws -> "aws"\n  | Gcp -> "gcp"\n  | Azure -> "azure"\n;;\n' \
  >"$tmp/namethird/cli/lib/base/sol_cli_provider.ml"
put namethird lib/sol_cli_azure_cluster.ml 'let argv = [ "azure"; "identity" ]'
expect_accept namethird "a third provider's name inside its own implementation"

mkcase stale 'dispatch cli/lib/a.ml 2
dispatch cli/lib/gone.ml 3'
put stale lib/a.ml "$exhaustive"
expect_reject stale "an allowlist entry for a module that no longer exists"

mkcase provider 'dispatch cli/lib/a.ml 2'
put provider lib/a.ml "$exhaustive"
put provider lib/sol_cli_provider.ml 'type t = Aws | Gcp
let to_string = function Aws -> "aws" | Gcp -> "gcp"'
expect_accept provider "the provider module's own constructors"

mkcase identity ''
put identity lib/a.ml 'let whoami_identity_of_json json = ignore json
;;'
expect_reject identity "a whoami identity parser declared in a generic module"

mkcase identityfield ''
put identityfield lib/a.ml 'type identity =
  { canonical_arn : string option
  ; username : string option
  }
;;'
expect_reject identityfield "a canonical_arn record field declared in a generic module"

mkcase identityok ''
put identityok lib/sol_cli_aws_cluster.ml 'let whoami_identity_of_json json = ignore json
;;
type identity =
  { canonical_arn : string option
  }
;;'
expect_accept identityok "the same declarations inside the AWS implementation"

mkcase third ''
printf 'let to_string = function\n  | Aws -> "aws"\n  | Gcp -> "gcp"\n  | Azure -> "azure"\n;;\n' \
  >"$tmp/third/cli/lib/base/sol_cli_provider.ml"
put third lib/sol_cli_azure_cluster.ml 'let argv = [ "azure"; "identity" ]
;;
let whoami_identity_of_json _ = Ok ()
;;'
expect_accept third "a third provider's own implementation"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "test_provider_dispatch_check: guard rejects new dispatch, growth, unrecorded reductions, wildcard provider arms, stale entries, provider-native identity declared in a generic module, and a provider's name spelled as a string there; accepts the baseline, allowlisted wildcards, nested non-provider wildcards, the provider module, identity or a provider name inside a provider implementation, and a provider this tree does not have yet."
