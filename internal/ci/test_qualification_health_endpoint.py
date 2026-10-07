"""Mutation coverage for check_qualification_health_endpoint.py.

Each case restores a probe the running service never served, or moves the
declaration out from under a harness, and must be rejected (sol-fab/sol#1283).
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "internal/ci/check_qualification_health_endpoint.py"
DECLARATION = "framework/ocaml/sol-svc/lib/service.ml"
TRANSPORT = "internal/qualification/aws/transport-transaction.sh"
APP = "internal/qualification/aws/app-transaction.sh"
GCP = "internal/qualification/gcp/live-qual.sh"


def replace(path, old, new):
    def mutate(root):
        target = root / path
        text = target.read_text()
        if old not in text:
            sys.exit(f"FAIL: a mutation's anchor no longer matches {path}: {old!r}")
        target.write_text(text.replace(old, new, 1))
    return mutate


CASES = [
    ("aws-transport-probes-undeclared", replace(
        TRANSPORT, "$URL/healthz", "$URL/health")),
    ("aws-app-probes-undeclared", replace(
        APP, "$URL/healthz", "$URL/health")),
    ("gcp-probes-undeclared", replace(
        GCP, "localhost:$port/healthz", "localhost:$port/health")),
    # The declaration is authoritative: moving it must fail the harnesses that
    # still probe the old path.
    ("declaration-moves", replace(
        DECLARATION, '("/healthz" | "/readyz")', '("/healthz2" | "/readyz")')),
    ("aws-app-stops-probing", replace(APP, "$URL/healthz", "$URL/")),
]


def tree(scratch, name):
    root = scratch / name
    shutil.copytree(REPO / "internal/qualification", root / "internal/qualification")
    (root / "framework/ocaml/sol-svc/lib").mkdir(parents=True)
    shutil.copy(REPO / DECLARATION, root / DECLARATION)
    return root


def verdict(root):
    run = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    return run.returncode, run.stdout + run.stderr


def main():
    print("check_qualification_health_endpoint mutations")
    with tempfile.TemporaryDirectory() as scratch:
        for name, mutate in CASES:
            root = tree(Path(scratch), name)
            mutate(root)
            rc, output = verdict(root)
            if rc == 0:
                sys.exit(f"FAIL: the guard accepted the '{name}' mutation:\n{output}")
            first = next(
                (line for line in output.splitlines() if line.startswith("FAIL")),
                output.splitlines()[0],
            )
            print(f"  rejected: {name} -- {first}")
        rc, output = verdict(tree(Path(scratch), "real-tree"))
        if rc != 0:
            sys.exit(f"FAIL: the guard rejected the unmutated tree:\n{output}")
        print("  accepted: real-tree (unmutated)")
    print("check_qualification_health_endpoint: all mutations rejected, unmutated tree accepted")


main()
