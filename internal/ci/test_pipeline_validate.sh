#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOLDEV="${SOLDEV:-$ROOT/_build/default/internal/tooling/soldev/bin/main.exe}"

fail() {
  echo "  [FAIL] $1"
  exit 1
}

ok() {
  echo "  [OK]   $1"
}

if [ ! -x "$SOLDEV" ]; then
  fail "soldev is not built at $SOLDEV (run: opam exec -- dune build)"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
TREE="$WORK/internal/pipeline/tickets"
mkdir -p "$TREE/BACKLOG" "$TREE/READY_FOR_ENGINEERING" "$TREE/DONE"

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
printf '#!/usr/bin/env bash\nprintf "[]\\n"\n' > "$STUB_BIN/gh"
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

readable() {
  printf -- '---\nid: %s\ntype: bug\nseverity: low\nsource: planted fixture\n---\n\n%s\n' "$1" "$2"
}

malformed() {
  printf -- '---\nid: %s\ntype: bug\nseverity: low\nsource: review - "a colon: inside a plain scalar"\n---\n\n%s\n' "$1" "$2"
}

run_in() {
  local dir="$1"
  shift
  local out
  if out="$(cd "$dir" && "$SOLDEV" "$@" 2>&1)"; then
    RC=0
  else
    RC=$?
  fi
  OUT="$out"
}

expect_rejected() {
  local what="$1" needle="$2"
  if [ "$RC" = 0 ]; then
    fail "$what: the command accepted it"
  fi
  case "$OUT" in
    *"$needle"*) ;;
    *) fail "$what: the output does not name $needle (got: $OUT)" ;;
  esac
}

run_in "$ROOT" pipeline validate
if [ "$RC" != 0 ]; then
  printf '%s\n' "$OUT"
  fail "the repository's own pipeline tree has an unreadable ticket"
fi
case "$OUT" in
  *"all readable"*) ok "the repository's tree validates (BACKLOG, READY, DONE)" ;;
  *) fail "validate did not report a clean tree (got: $OUT)" ;;
esac

readable BUG-900 "a readable backlog ticket" > "$TREE/BACKLOG/BUG-900.md"
readable BUG-901 "a readable done ticket" > "$TREE/DONE/BUG-901.md"
run_in "$WORK" pipeline validate
[ "$RC" = 0 ] || fail "a fixture tree of readable tickets was rejected: $OUT"
ok "a fixture tree of readable tickets passes (the mutation below is not vacuous)"

readable BUG-900 "duplicate id" > "$TREE/DONE/BUG-900.md"
run_in "$WORK" pipeline validate
expect_rejected "validate, duplicate ticket id" "duplicate ticket id BUG-900"
ok "validate rejects duplicate ids across ticket states"
rm "$TREE/DONE/BUG-900.md"

readable BUG-906 "mismatched id" > "$TREE/BACKLOG/BUG-907.md"
run_in "$WORK" pipeline validate
expect_rejected "validate, id differs from filename" "frontmatter id BUG-906 does not match filename id BUG-907"
ok "validate rejects a frontmatter id that differs from its filename"
rm "$TREE/BACKLOG/BUG-907.md"

before="$(cat "$TREE/BACKLOG/BUG-900.md")"
malformed BUG-900 "malformed frontmatter" > "$TREE/BACKLOG/BUG-900.md"
after="$(cat "$TREE/BACKLOG/BUG-900.md")"
[ "$before" != "$after" ] || fail "the mutation did not change the fixture"
ok "the malformed fixture differs from the readable one it replaces"

run_in "$WORK" pipeline validate
expect_rejected "validate, malformed frontmatter" "BACKLOG/BUG-900.md"
case "$OUT" in
  *"not valid YAML"*) ok "validate names the malformed file and its parse error" ;;
  *) fail "validate did not report the parse failure (got: $OUT)" ;;
esac

printf -- '# BUG-902 — no frontmatter block\n\nBody.\n' > "$TREE/DONE/BUG-902.md"
run_in "$WORK" pipeline validate
expect_rejected "validate, no frontmatter block" "DONE/BUG-902.md"
ok "validate covers DONE, and a ticket with no frontmatter is an error"

printf -- '---\nid: BUG-903\ntype: bug\nsource: planted fixture\n---\n\nBody.\n' > "$TREE/BACKLOG/BUG-903.md"
run_in "$WORK" pipeline validate
expect_rejected "validate, missing field" "BACKLOG/BUG-903.md"
case "$OUT" in
  *'`severity`'*) ok "validate names the missing field" ;;
  *) fail "validate did not name the missing field (got: $OUT)" ;;
esac

run_in "$WORK" pipeline ls
expect_rejected "ls, unreadable ticket in a scanned state" "BACKLOG/BUG-900.md"
ok "pipeline ls exits non-zero and names what it could not read"

run_in "$WORK" pipeline check BUG-900
expect_rejected "check, unreadable ticket" "BACKLOG/BUG-900.md"
ok "pipeline check refuses to answer for an unreadable ticket"

rm -f "$TREE/BACKLOG/BUG-900.md" "$TREE/BACKLOG/BUG-903.md"
run_in "$WORK" pipeline ls
[ "$RC" = 0 ] || fail "a tree of readable tickets failed the listing: $OUT"
ok "the listing is green again once the unreadable tickets are gone"

probe_marker="$WORK/probe-ran"
printf -- '---\nid: BUG-904\ntype: bug\nsource: planted fixture\npremise: "touch %s"\n---\n\nMissing severity.\n' "$probe_marker" > "$TREE/BACKLOG/BUG-904.md"
rm -f "$probe_marker"
run_in "$WORK" pipeline ls
expect_rejected "ls, a rejected ticket that declares a premise probe" "BACKLOG/BUG-904.md"
case "$OUT" in
  *premise-*) fail "the listing decorated a rejected ticket as readable ($OUT)" ;;
esac
[ ! -e "$probe_marker" ] || fail "a premise probe ran for a ticket the listing rejected"
ok "a rejected ticket is not decorated, and its probe does not run"

printf -- '---\nid: BUG-905\ntype: bug\nseverity: low\nsource: planted fixture\npremise: "touch %s"\n---\n\nReadable.\n' "$probe_marker" > "$TREE/BACKLOG/BUG-905.md"
rm -f "$probe_marker"
run_in "$WORK" pipeline ls
[ -e "$probe_marker" ] || fail "the control probe did not run for a readable ticket"
ok "the control probe does run for a readable ticket (so the check above is not vacuous)"

echo "pipeline ticket validation guard: all expectations hold."
