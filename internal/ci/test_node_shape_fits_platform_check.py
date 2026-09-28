import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "internal/ci/check_node_shape_fits_platform.py"
GCP = "platform/cloud/gcp/cluster/variables.tf"
AWS = "platform/cloud/aws/cluster/variables.tf"
PROFILE = "cli/lib/base/sol_cli_profile.ml"
COPIED = (GCP, AWS, PROFILE)


def substitute(relative, pattern, replacement):
    def mutate(root):
        path = root / relative
        text, n = re.subn(pattern, replacement, path.read_text(), count=1)
        assert n == 1, "the mutation anchor did not match"
        path.write_text(text)
    return mutate


def drop_default(relative, variable):
    def mutate(root):
        path = root / relative
        text, n = re.subn(
            rf'(variable "{variable}" \{{[^}}]*?)\n\s*default\s*=\s*[^\n]+', r"\1", path.read_text(), count=1
        )
        assert n == 1, "the mutation anchor did not match"
        path.write_text(text)
    return mutate


CASES = [
    ("gcp-shape-below-the-profile-minimum", substitute(
        GCP, r'default\s*=\s*"e2-standard-4"', 'default     = "e2-standard-2"')),
    ("aws-shape-below-the-profile-minimum", substitute(
        AWS, r'default\s*=\s*\["m6i\.xlarge"\]', 'default     = ["m6i.large"]')),
    ("gcp-count-below-the-envelope", substitute(
        GCP, r'(variable "node_count" \{[^}]*?default\s*=\s*)4', r"\g<1>3")),
    ("aws-count-below-the-envelope", substitute(
        AWS, r'(variable "node_desired_size" \{[^}]*?default\s*=\s*)4', r"\g<1>3")),
    ("envelope-minimum-raised", substitute(
        PROFILE, r"min_vcpu_per_node = 4", "min_vcpu_per_node = 6")),
    ("envelope-field-removed", substitute(
        PROFILE, r"\n\s*; min_vcpu_per_node = 4", "")),
    ("unknown-shape", substitute(
        GCP, r'default\s*=\s*"e2-standard-4"', 'default     = "n2-standard-4"')),
    ("gcp-shape-default-removed", drop_default(GCP, "node_machine_type")),
    ("aws-count-default-removed", drop_default(AWS, "node_desired_size")),
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
    print("check_node_shape_fits_platform mutations")
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
    print("check_node_shape_fits_platform: all mutations rejected, unmutated tree accepted")


main()
