import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "internal/ci/check_platform_component_drift.py"
FILES = [
    "cli/bin/cmd_local.ml",
    "cli/lib/local/sol_cli_local_platform.ml",
    "cli/lib/local/sol_cli_dev_observability.ml",
    "platform/cloud/modules/platform/main.tf",
    "platform/shared/components.json",
]


def append(path, text):
    def mutate(root):
        with open(root / path, "a", encoding="utf-8") as f:
            f.write(text)
    return mutate


def break_layers(root):
    path = root / "platform/shared/components.json"
    data = json.loads(path.read_text())
    first = sorted(data)[0]
    data[first]["prod"] = data[first].pop("durable")
    path.write_text(json.dumps(data))


def drop_env_from_tf(root):
    path = root / "platform/cloud/modules/platform/main.tf"
    text = path.read_text()
    path.write_text(text.replace('"workspace", "env", "domain"', '"workspace", "domain"', 1))


def drop_env_from_ocaml(root):
    path = root / "cli/lib/local/sol_cli_dev_observability.ml"
    text = path.read_text()
    path.write_text(text.replace('"workspace"; "env"; "domain"', '"workspace"; "domain"', 1))


def drift_the_ocaml_mirror(root):
    path = root / "cli/lib/local/sol_cli_dev_observability.ml"
    text = path.read_text()
    path.write_text(text.replace('"primitive"; "release" ]', '"primitive"; "release"; "region" ]', 1))


CASES = [
    ("a migrated key back in the local platform", "fail",
     append("cli/lib/local/sol_cli_local_platform.ml", '\nlet _ = "deploymentMode"\n')),
    ("a migrated key back in cmd_local", "fail", append("cli/bin/cmd_local.ml", '\nlet _ = "gateway.enabled"\n')),
    ("a migrated key back in main.tf", "fail",
     append("platform/cloud/modules/platform/main.tf", '\nlocals {\n  drift = "loki.auth_enabled"\n}\n')),
    ("a local-only key back in the local platform", "fail",
     append("cli/lib/local/sol_cli_local_platform.ml", '\nlet _ = "statefulset.replicas"\n')),
    ("a local-only key in main.tf is allowed", "pass",
     append("platform/cloud/modules/platform/main.tf", '\nlocals {\n  allowed = "statefulset.replicas"\n}\n')),
    ("a component keyed by environment", "fail", break_layers),
    ("env dropped from the cloud log taxonomy", "fail", drop_env_from_tf),
    ("env dropped from the local log taxonomy mirror", "fail", drop_env_from_ocaml),
    ("the local log taxonomy mirror drifts from the cloud", "fail", drift_the_ocaml_mirror),
    ("the real tree", "pass", lambda root: None),
]


def main():
    with tempfile.TemporaryDirectory() as scratch:
        for name, want, mutate in CASES:
            root = Path(scratch) / name.replace(" ", "-")
            for rel in FILES:
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(REPO / rel, root / rel)
            mutate(root)
            run = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
            got = "pass" if run.returncode == 0 else "fail"
            if got != want:
                sys.exit(f"  [FAIL] {name}: expected {want}, got {got}\n{run.stdout}{run.stderr}")
            print(f"  [OK]   {name}")


main()
