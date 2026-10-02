#!/usr/bin/env python3
"""Mutation test for check_authorization_fence.

Each case is a way DEC-062 rule 2 can break again: the boundary condition
dropped, the create-role resource widened, the boundary-replacement deny
removed, a service-account-creation permission added, or the resource-scoped
grant permission removed. Each must be rejected, for its own reason.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "internal/ci/check_authorization_fence.py"
AWS_ROOT = "platform/cloud/aws/authorization/main.tf"
GCP_ROOT = "platform/cloud/gcp/authorization/main.tf"
COPIED = [AWS_ROOT, GCP_ROOT, "internal/ci/lib/tfconfig.py"]


def scratch():
    tmp = Path(tempfile.mkdtemp())
    for relative in COPIED:
        target = tmp / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / relative, target)
    guard_target = tmp / "internal/ci/check_authorization_fence.py"
    guard_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(GUARD, guard_target)
    return tmp


def run(tmp):
    return subprocess.run(
        [sys.executable, str(tmp / "internal/ci/check_authorization_fence.py"), str(tmp)],
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

    real = run(scratch())
    if real.returncode != 0:
        failures.append("the real tree was rejected:\n" + real.stdout + real.stderr)

    cases = [
        (
            "the boundary condition is dropped from the create-role allow",
            AWS_ROOT,
            'variable = "iam:PermissionsBoundary"',
            'variable = "aws:RequestedRegion"',
            "PermissionsBoundary",
        ),
        (
            "the create-role resource is widened to everything",
            AWS_ROOT,
            'actions   = ["iam:CreateRole"]\n    resources = ["arn:aws:iam::${local.account_id}:role/${local.role_path}*"]',
            'actions   = ["iam:CreateRole"]\n    resources = ["*"]',
            "resource-scoped",
        ),
        (
            "the boundary-replacement deny is removed",
            AWS_ROOT,
            '"iam:DeleteRolePermissionsBoundary",',
            '"iam:ListRoles",',
            "DeleteRolePermissionsBoundary",
        ),
        (
            "a service-account-creation permission is added",
            GCP_ROOT,
            '"secretmanager.secrets.get",',
            '"secretmanager.secrets.get",\n    "iam.serviceAccounts.create",',
            "iam.serviceAccounts.create",
        ),
        (
            "the resource-scoped grant permission is removed",
            GCP_ROOT,
            '"secretmanager.secrets.setIamPolicy",',
            '"secretmanager.secrets.getIamPolicy",',
            "setIamPolicy is absent",
        ),
    ]

    for label, relative, old, new, reason in cases:
        tmp = scratch()
        mutate(tmp, relative, old, new)
        result = run(tmp)
        output = result.stdout + result.stderr
        if result.returncode == 0:
            failures.append(f"{label}: the guard accepted it")
        elif reason not in output:
            failures.append(f"{label}: rejected for the wrong reason:\n{output}")

    if failures:
        print("test_authorization_fence_check: FAIL", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        sys.exit(1)

    print("test_authorization_fence_check: PASS")


if __name__ == "__main__":
    main()
