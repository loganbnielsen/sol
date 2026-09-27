#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/internal/ci/check_framework_doc_signatures.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/framework/ocaml"
cp -r "$ROOT/framework/ocaml/sol-svc" "$work/framework/ocaml/"
cp -r "$ROOT/framework/ocaml/kafka-eio-service" "$work/framework/ocaml/"

SVC="$work/framework/ocaml/sol-svc/sol-svc.md"
KAFKA="$work/framework/ocaml/kafka-eio-service/kafka-eio-service.md"

cp "$SVC" "$work/svc.orig"
cp "$KAFKA" "$work/kafka.orig"
restore() {
  cp "$work/svc.orig" "$SVC"
  cp "$work/kafka.orig" "$KAFKA"
}

expect_pass() {
  local what="$1"
  if ! "$CHECK" --root "$work" >/dev/null 2>&1; then
    echo "  [FAIL] $what should pass" >&2
    "$CHECK" --root "$work" >&2 || true
    exit 1
  fi
  echo "  [OK]   $what passes"
}

expect_fail() {
  local what="$1"
  if "$CHECK" --root "$work" >/dev/null 2>&1; then
    echo "  [FAIL] $what was accepted" >&2
    exit 1
  fi
  echo "  [OK]   $what is refused"
}

expect_pass "the committed specs"

python3 - "$SVC" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()
t = t.replace("  ; trace_ctx : Obs_trace.t option\n", "", 1)
p.write_text(t)
PY
expect_fail "a dropped Request.t field"
restore

python3 - "$KAFKA" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(
    "val config_of_env : unit -> (config, error) result",
    "val config_of_env : unit -> config", 1))
PY
expect_fail "a signature missing its result"
restore

python3 - "$SVC" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()
marker = "val internal_error  : string -> t"
assert marker in t, "the fixture moved; update this test"
p.write_text(t.replace(marker, marker + "\nval not_implemented : t", 1))
PY
expect_fail "a member the .mli does not export"
restore

python3 - "$KAFKA" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(
    "| In_memory of Kafka.Consumer.retry_policy",
    "| In_memory of Kafka_consumer.retry_policy", 1))
PY
expect_fail "an old flat module name"
restore

python3 - "$KAFKA" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(
    "-> raw_bytes:bytes option", "-> raw_bytes:bytes", 1))
PY
expect_fail "a changed argument shape"
restore

python3 - "$SVC" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()
marker = "val query_params : t -> string -> string list"
assert marker in t, "the fixture moved; update this test"
p.write_text(t.replace(marker, "", 1))
PY
expect_pass "a spec that shows fewer declarations than the .mli"
restore

expect_pass "the committed specs again"

echo "framework doc signature guard: all expectations hold."
