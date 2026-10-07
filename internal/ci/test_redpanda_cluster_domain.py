"""Mutation coverage for check_redpanda_cluster_domain.py.

Each case removes the pin or restores the shape that made the workloads unable to
consume Kafka (sol-fab/sol#1279), and must be rejected.
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "internal/ci/check_redpanda_cluster_domain.py"
COMPONENTS = "platform/shared/components.json"
MODULE = "platform/cloud/modules/platform/main.tf"
PIN = '      "clusterDomain": "cluster.local",\n'


def replace(path, old, new, count=1):
    def mutate(root):
        target = root / path
        text = target.read_text()
        if old not in text:
            sys.exit(f"FAIL: a mutation's anchor no longer matches {path}: {old!r}")
        target.write_text(text.replace(old, new, count))
    return mutate


CASES = [
    # The chart's own default is `cluster.local.`, so dropping the pin restores the
    # defect exactly.
    ("pin-removed", replace(COMPONENTS, PIN, "")),
    ("pin-dotted", replace(COMPONENTS, PIN, '      "clusterDomain": "cluster.local.",\n')),
    ("pin-empty", replace(COMPONENTS, PIN, '      "clusterDomain": "",\n')),
    ("pin-other-domain", replace(COMPONENTS, PIN, '      "clusterDomain": "my.cluster",\n')),
    ("components-values-not-passed", replace(
        MODULE, "    jsonencode(local.platform_components.redpanda.common),\n", "")),
]


def tree(scratch, name):
    root = scratch / name
    (root / "platform/shared").mkdir(parents=True)
    (root / "platform/cloud/modules/platform").mkdir(parents=True)
    shutil.copy(REPO / COMPONENTS, root / COMPONENTS)
    shutil.copy(REPO / MODULE, root / MODULE)
    return root


def verdict(root):
    run = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    return run.returncode, run.stdout + run.stderr


def main():
    print("check_redpanda_cluster_domain mutations")
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
    print("check_redpanda_cluster_domain: all mutations rejected, unmutated tree accepted")


main()
