import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "internal/ci/check_platform_tls_requirement.py"
MODULE = "platform/cloud/modules/platform/main.tf"
DECLARATION = "cli/lib/cloud/sol_cli_platform_tls.ml"
LIFECYCLE = "cli/lib/cloud/sol_cli_cloud_lifecycle.ml"
COPIED = (MODULE, DECLARATION, LIFECYCLE)


def substitute(relative, pattern, replacement, count=1):
    def mutate(root):
        path = root / relative
        text, changed = re.subn(pattern, replacement, path.read_text(), count=count)
        assert changed >= 1, f"the mutation anchor {pattern!r} did not match in {relative}"
        path.write_text(text)
    return mutate


CASES = [
    ("the-declaration-renames-a-certificate", substitute(
        DECLARATION, r'certificate = "grafana-tls"', 'certificate = "grafana-cert"')),
    ("the-declaration-attributes-nothing", substitute(
        DECLARATION,
        r"the shared platform module's Grafana ingress declares this TLS secret",
        "a certificate")),
    ("the-module-renames-a-declared-secret", substitute(
        MODULE, r'secret_name = "grafana-tls"', 'secret_name = "grafana-certs"')),
    ("the-module-stops-requesting-a-certificate", substitute(
        MODULE, r'\n\s*"cert-manager\.io/cluster-issuer"\s*=\s*var\.cluster_issuer', "")),
    ("the-readiness-checks-stop-deriving-from-the-declaration", substitute(
        LIFECYCLE, r'    Sol_cli_platform_tls\.certificates', "    []")),
]


def tree(scratch, name):
    root = scratch / name
    for relative in COPIED:
        (root / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(REPO / relative, root / relative)
    return root


def snapshot(root):
    return sorted((p, p.read_bytes()) for p in root.rglob("*") if p.is_file())


def verdict(root):
    run = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    return run.returncode, run.stdout + run.stderr


def main():
    print("check_platform_tls_requirement mutations")
    with tempfile.TemporaryDirectory() as scratch:
        for name, mutate in CASES:
            root = tree(Path(scratch), name)
            before = snapshot(root)
            mutate(root)
            if snapshot(root) == before:
                sys.exit(f"FAIL: the '{name}' mutation did not change the tree at all")
            rc, output = verdict(root)
            if rc == 0:
                sys.exit(f"FAIL: the guard accepted the '{name}' mutation:\n{output}")
            first = next((line for line in output.splitlines() if line.startswith("FAIL")), "")
            print(f"  rejected: {name} -- {first[:88]}")
        rc, output = verdict(tree(Path(scratch), "real-tree"))
        if rc != 0:
            sys.exit(f"FAIL: the guard rejected the unmutated tree (real-tree):\n{output}")
        print(f"  accepted: real-tree -- {output.strip()[:100]}")
    print("check_platform_tls_requirement: all mutations rejected, unmutated tree accepted")


main()
