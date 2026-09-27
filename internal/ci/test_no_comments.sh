#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_no_comments.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run() {
  local want="$1" name="$2" file="$3" content="$4"
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/$(dirname "$file")"
  git -C "$tmp/repo" init -q
  printf '%s\n' "$content" >"$tmp/repo/$file"
  git -C "$tmp/repo" add -A
  if "$CHECK" "$tmp/repo" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" != "$want" ]; then
    echo "  [FAIL] $name (expected $want, got $got)"
    exit 1
  fi
  echo "  [OK]   $name"
}

run pass "ocaml: plain code" lib/a.ml 'let x = 1'
run pass "ocaml: an opener inside a string" lib/a.ml 'let s = "(* not a comment *)"'
run pass "ocaml: an opener inside a quoted string" lib/a.ml 'let s = {|(* not a comment *)|}'
run pass "ocaml: the multiplication operator" lib/a.ml 'let f = ( * ) 2'
run pass "ocaml: an escaped quote in a string" lib/a.ml 'let s = "a \" (* b"'
run fail "ocaml: a comment" lib/a.ml 'let x = 1 (* one *)'
run fail "ocaml: a doc comment" lib/a.ml '(** the answer *)
let x = 42'
run fail "ocaml: a comment after a character literal" lib/a.ml "let q = '\"' (* quote *)"
run fail "ocaml: a comment after a type variable" lib/a.ml "type 'a t = 'a list (* list *)"

run pass "shell: a shebang and a shellcheck directive" bin/a.sh '#!/usr/bin/env bash
# shellcheck disable=SC2086
echo "$#" "${#x}" '"'"'#'"'"' "a # b"'
run pass "shell: a # inside a heredoc" bin/a.sh 'cat <<EOF
# data, not a comment
EOF'
run pass "shell: a # inside a nested command substitution" bin/a.sh 'x="$(grep "#" f)"'
run fail "shell: a comment line" bin/a.sh '#!/usr/bin/env bash
# why
true'
run fail "shell: a trailing comment" bin/a.sh 'true # why'
run fail "shell: an empty comment" bin/a.sh 'true
#'
run fail "shell: a hook without an extension" internal/tooling/hooks/pre-commit '# why
true'

run pass "terraform: a # inside a string and a heredoc" main.tf 'locals {
  a = "#${var.x}//"
  b = <<EOT
# data
EOT
}'
run fail "terraform: a # comment" main.tf '# why
locals {}'
run fail "terraform: a // comment" main.tf 'locals {} // why'
run fail "terraform: a block comment" main.tf '/* why */ locals {}'

run pass "typescript: // inside strings, templates and regexes" src/a.ts 'const a = "//x"; const b = `/* ${c} */`; const d = /\/\//g;'
run pass "typescript: tool directives" src/a.ts '/// <reference types="node" />
// @ts-expect-error
const a: number = "x";'
run fail "typescript: a line comment" src/a.ts 'const a = 1; // why'
run fail "typescript: a block comment" src/a.ts '/* why */ const a = 1;'

run pass "python: a shebang, # in strings, and tool directives" tools/a.py '#!/usr/bin/env python3
import os  # noqa: F401
x = "# not a comment"
y = """
# also a string
"""'
run fail "python: a comment line" tools/a.py '# why
x = 1'
run fail "python: a trailing comment" tools/a.py 'x = 1  # why'

run pass "dune: ; inside a string" test/dune '(rule (action (run echo "a ; b")))'
run fail "dune: a line comment" test/dune '; why
(rule (action (run echo a)))'
run fail "dune: a block comment" dune-project '#| why |#
(lang dune 3.0)'
run fail "dune: a datum comment" test/dune '(rule #;(deps x) (action (run echo a)))'
run pass "Dockerfile: a parser directive" app/Dockerfile '# syntax=docker/dockerfile:1
FROM scratch'
run fail "Dockerfile: a comment" app/Dockerfile 'FROM scratch
# why
USER 65534'
run fail "Dockerfile: a named Dockerfile" tools/runner.Dockerfile '# why
FROM scratch'
