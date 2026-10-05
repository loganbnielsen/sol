#!/usr/bin/env python3
"""Mutation test for check_deploy_identity_separation.

Each case is a way the identity separation can break: the platform provisioner
widened with namespaced rolebindings, or the platform cluster-access entry given
the deployers group. Each must be rejected for its own reason.
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "internal/ci/check_deploy_identity_separation.py"
COPIED = [
    "platform/cloud/modules/platform/platform_provisioner_rbac.tf",
    "platform/cloud/aws/cluster/main.tf",
]


def scratch():
    tmp = Path(tempfile.mkdtemp())
    for relative in COPIED:
        target = tmp / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / relative, target)
    guard_target = tmp / "internal/ci/check_deploy_identity_separation.py"
    guard_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(GUARD, guard_target)
    return tmp


def run(tmp):
    return subprocess.run(
        [sys.executable, str(tmp / "internal/ci/check_deploy_identity_separation.py"), str(tmp)],
        capture_output=True,
        text=True,
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
        failures.append("the real tree was rejected:\n" + result.stdout + result.stderr)

    cases = []

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/modules/platform/platform_provisioner_rbac.tf",
        '''    resources  = ["clusterroles", "clusterrolebindings"]''',
        '''    resources  = ["clusterroles", "clusterrolebindings", "rolebindings"]''',
    )
    cases.append(("provisioner-widened", tmp, "widens the platform identity"))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/aws/cluster/main.tf",
        '''        kubernetes_groups = ["sol:platform-provisioners"]''',
        '''        kubernetes_groups = ["sol:platform-provisioners", "sol:deployers"]''',
    )
    cases.append(("cluster-access-gets-the-deployers-group", tmp, "no longer separated"))

    for name, tmp, expected in cases:
        result = run(tmp)
        if result.returncode == 0:
            failures.append(f"{name}: accepted a broken tree")
        elif expected not in (result.stdout + result.stderr):
            failures.append(
                f"{name}: rejected, but not for the invariant it breaks "
                f"(wanted {expected!r}):\n{result.stdout}{result.stderr}"
            )

    if failures:
        print("test_deploy_identity_separation_check: FAILED")
        for failure in failures:
            print(f"  {failure}")
        return 1

    print(
        "test_deploy_identity_separation_check: the guard accepts the real tree and "
        f"rejects {len(cases)} mutations for their own reasons"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
