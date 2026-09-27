import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "internal/ci/check_terraform_output_fixture.py"
FIXTURE = "cli/test/fixtures/terraform-output-gcp-cloud.json"
HARNESS = "internal/ci/test_cloud_lifecycle_offline.sh"
PARSER = "cli/lib/cloud/sol_cli_gcp_cluster.ml"


def edit_fixture(change):
    def mutate(root):
        path = root / FIXTURE
        data = json.loads(path.read_text())
        change(data)
        path.write_text(json.dumps(data, indent=2))
    return mutate


def replace(path, old, new, every=False):
    def mutate(root):
        text = (root / path).read_text()
        if old not in text:
            sys.exit(f"FAIL: a mutation's anchor no longer matches {path}: {old!r}")
        (root / path).write_text(text.replace(old, new) if every else text.replace(old, new, 1))
    return mutate


def invent_old_shape(root):
    path = root / HARNESS
    text = path.read_text()
    anchor = "sed -e 's#sol-qual-gcp-13#sol-qual#g'"
    lines = [line for line in text.splitlines() if anchor in line]
    if not lines:
        sys.exit(f"FAIL: a mutation's anchor no longer matches {HARNESS}: {anchor!r}")
    invented = "printf '{\"project_id\":{\"value\"}}'"
    path.write_text(text.replace(lines[0], invented + "\n" + lines[0], 1))


CASES = [
    ("no-type", edit_fixture(lambda d: d["project_id"].pop("type"))),
    ("project-is-not-a-string", edit_fixture(lambda d: d["project_id"].__setitem__("value", 42))),
    ("no-project-id", edit_fixture(lambda d: d.pop("project_id"))),
    ("sensitive-not-a-bool", edit_fixture(lambda d: d["project_id"].__setitem__("sensitive", "false"))),
    ("harness-declares-its-own-shape", replace(HARNESS, f'"$REPO_ROOT/{FIXTURE}"', '"$tmp/gcp-outputs.json"')),
    ("harness-invents-the-old-shape", invent_old_shape),
    ("parser-reads-a-private-shape", replace(PARSER, "Sol_cli_cluster.outputs_reader", "Sol_cli_gcp_private_reader", every=True)),
]


def tree(scratch, name):
    root = scratch / name
    for rel in (FIXTURE, HARNESS, PARSER):
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(REPO / rel, root / rel)
    return root


def verdict(root):
    run = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    return run.returncode, run.stdout + run.stderr


def main():
    print("check_terraform_output_fixture mutations")
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
    print("check_terraform_output_fixture: all mutations rejected, unmutated tree accepted")


main()
