import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "internal/ci/check_platform_storage_requirement.py"
DECLARATION = "cli/lib/cloud/sol_cli_platform_storage.ml"
MODULE = "platform/cloud/modules/platform/main.tf"
COMPONENTS = "platform/shared/components.json"


def replace(path, old, new):
    def mutate(root):
        text = (root / path).read_text()
        if old not in text:
            sys.exit(f"FAIL: a mutation's anchor no longer matches {path}: {old!r}")
        (root / path).write_text(text.replace(old, new, 1))
    return mutate


def substitute(path, pattern, replacement):
    def mutate(root):
        text, n = re.subn(pattern, replacement, (root / path).read_text(), count=1)
        if n != 1:
            sys.exit(f"FAIL: a mutation's pattern no longer matches {path}: {pattern!r}")
        (root / path).write_text(text)
    return mutate


CASES = [
    ("no-provenance", replace(
        DECLARATION, '; provenance =\n        "chart default for Loki', '; provenance =\n        "" , "chart default for Loki')),
    ("claims-a-sol-size", replace(
        DECLARATION, '"chart default for the prometheus server',
        '"var.prometheus_persistent_storage default for the prometheus server')),
    ("provenance-without-attribution", substitute(
        DECLARATION, r'"chart default for the prometheus server[^"]*"', '"a number with no stated source"')),
    ("loki-persistence-disabled", replace(
        MODULE, 'name  = "singleBinary.persistence.enabled"', 'name  = "singleBinary.persistence.removed"')),
    ("alertmanager-disabled", replace(
        COMPONENTS, '"alertmanager": {\n        "enabled": true', '"alertmanager": {\n        "enabled": false')),
    ("prometheus-values-not-from-components", replace(
        MODULE, "    local.prometheus_component_values,\n", "")),
]


def tree(scratch, name):
    root = scratch / name
    shutil.copytree(REPO / "platform/cloud/modules", root / "platform/cloud/modules")
    shutil.copytree(REPO / "platform/cloud/gcp", root / "platform/cloud/gcp")
    for rel in (DECLARATION, COMPONENTS):
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(REPO / rel, root / rel)
    return root


def verdict(root):
    run = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    return run.returncode, run.stdout + run.stderr


def main():
    print("check_platform_storage_requirement mutations")
    with tempfile.TemporaryDirectory() as scratch:
        for name, mutate in CASES:
            root = tree(Path(scratch), name)
            mutate(root)
            rc, output = verdict(root)
            if rc == 0:
                sys.exit(f"FAIL: the guard accepted the '{name}' mutation:\n{output}")
            first = next((l for l in output.splitlines() if l.startswith("FAIL")), output.splitlines()[0])
            print(f"  rejected: {name} -- {first}")
        rc, output = verdict(tree(Path(scratch), "real-tree"))
        if rc != 0:
            sys.exit(f"FAIL: the guard rejected the unmutated tree (real-tree):\n{output}")
        print("  accepted: real-tree (unmutated)")
    print("check_platform_storage_requirement: all mutations rejected, unmutated tree accepted")


main()
