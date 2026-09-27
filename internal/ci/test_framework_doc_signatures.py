import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "internal/ci/check_framework_doc_signatures.py"
SVC = "framework/ocaml/sol-svc/sol-svc.md"
KAFKA = "framework/ocaml/kafka-eio-service/kafka-eio-service.md"

CASES = [
    ("a dropped Request.t field", "fail", SVC, "  ; trace_ctx : Obs_trace.t option\n", ""),
    ("a signature missing its result", "fail", KAFKA,
     "val config_of_env : unit -> (config, error) result", "val config_of_env : unit -> config"),
    ("a member the .mli does not export", "fail", SVC,
     "val internal_error  : string -> t", "val internal_error  : string -> t\nval not_implemented : t"),
    ("an old flat module name", "fail", KAFKA,
     "| In_memory of Kafka.Consumer.retry_policy", "| In_memory of Kafka_consumer.retry_policy"),
    ("a changed argument shape", "fail", KAFKA, "-> raw_bytes:bytes option", "-> raw_bytes:bytes"),
    ("a spec that shows fewer declarations than the .mli", "pass", SVC,
     "val query_params : t -> string -> string list", ""),
]


def verdict(root):
    return subprocess.run([sys.executable, str(GUARD), "--root", str(root)], capture_output=True, text=True)


def main():
    with tempfile.TemporaryDirectory() as scratch:
        root = Path(scratch)
        for package in ("sol-svc", "kafka-eio-service"):
            shutil.copytree(REPO / "framework/ocaml" / package, root / "framework/ocaml" / package)
        originals = {rel: (root / rel).read_text() for rel in (SVC, KAFKA)}
        if verdict(root).returncode != 0:
            sys.exit(f"  [FAIL] the committed specs should pass\n{verdict(root).stdout}")
        print("  [OK]   the committed specs pass")
        for what, want, rel, old, new in CASES:
            text = originals[rel]
            if old not in text:
                sys.exit(f"  [FAIL] the fixture moved; update this test: {old!r} is not in {rel}")
            (root / rel).write_text(text.replace(old, new, 1))
            got = "pass" if verdict(root).returncode == 0 else "fail"
            (root / rel).write_text(text)
            if got != want:
                sys.exit(f"  [FAIL] {what}: expected {want}, got {got}")
            print(f"  [OK]   {what} {'passes' if want == 'pass' else 'is refused'}")
        if verdict(root).returncode != 0:
            sys.exit("  [FAIL] the committed specs should pass again")
        print("  [OK]   the committed specs again passes")
    print("framework doc signature guard: all expectations hold.")


main()
