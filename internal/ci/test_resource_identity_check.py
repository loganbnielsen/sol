#!/usr/bin/env python3
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "internal/ci/check_resource_identity.py"
COPIED = [
    "cli/lib/cloud/sol_cli_resource_identity.ml",
    "platform/cloud/gcp/cluster/main.tf",
    "platform/cloud/gcp/cluster/variables.tf",
    "platform/cloud/aws/cluster/main.tf",
    "platform/cloud/aws/cluster/variables.tf",
    "platform/cloud/modules/platform/main.tf",
    "platform/cloud/modules/platform/cert_manager_issuer.tf",
]


def scratch():
    tmp = Path(tempfile.mkdtemp())
    for relative in COPIED:
        source = ROOT / relative
        target = tmp / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(source, target)
    return tmp


def run(tmp):
    return subprocess.run(
        [sys.executable, str(GUARD), str(tmp)], capture_output=True, text=True
    )


def mutate(tmp, relative, old, new):
    path = tmp / relative
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"mutation anchor not found in {relative}: {old!r}")
    path.write_text(text.replace(old, new, 1))


def main():
    failures = []

    result = run(scratch())
    if result.returncode != 0:
        failures.append("the real tree was rejected:\n" + result.stderr)

    cases = []

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/gcp/cluster/main.tf",
        'resource "google_container_cluster" "main" {',
        'resource "google_container_cluster" "a_new_thing_terraform_would_own" {',
    )
    cases.append(("a directly managed resource with no registry entry", tmp))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_resource_identity.ml",
        """      "google_sql_database_instance.postgres"
      direct
      ~identity:(cluster_name ^ "-postgres")
      ~import_identity:(cluster_name ^ "-postgres")""",
        """      "google_sql_database_instance.postgres"
      direct
      ~identity:(cluster_name ^ "-postgres")""",
    )
    cases.append(("a Direct entry whose import identity was removed", tmp))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_resource_identity.ml",
        '"google_compute_network.main"',
        '"google_compute_network.a_resource_no_root_declares"',
    )
    cases.append(("a stale entry naming a resource Sol does not have", tmp))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_resource_identity.ml",
        '{ terraform_type = "kubernetes_"; ownership = in_cluster }',
        '{ terraform_type = "kubernetes_object_"; ownership = in_cluster }',
    )
    cases.append(("a class-level rule that no longer covers the in-cluster family", tmp))

    for label, tmp in cases:
        result = run(tmp)
        if result.returncode == 0:
            failures.append(f"the guard accepted {label}")
        else:
            print(f"  rejected: {label}")

    shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        for failure in failures:
            print(f"test_resource_identity_check: {failure}", file=sys.stderr)
        return 1
    print(
        "test_resource_identity_check: the guard accepts the real tree and rejects an unregistered "
        "directly managed resource, a Direct entry without an import identity, a stale entry, and a "
        "class-level rule that stopped covering its family"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
