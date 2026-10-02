#!/usr/bin/env python3
"""Mutation test for check_deploy_identity_iam.

Each case is a way DEC-062 rule 1 can break again: an Allow that slips an IAM
write into the deploy identity, or the `iam:*` deny narrowed so the identity
holds IAM authority again. Each must be rejected, for its own reason.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "internal/ci/check_deploy_identity_iam.py"
BOOTSTRAP = "platform/cloud/aws/bootstrap/main.tf"
COPIED = [BOOTSTRAP, "internal/ci/lib/tfconfig.py"]


def scratch():
    tmp = Path(tempfile.mkdtemp())
    for relative in COPIED:
        target = tmp / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / relative, target)
    guard_target = tmp / "internal/ci/check_deploy_identity_iam.py"
    guard_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(GUARD, guard_target)
    return tmp


def run(tmp):
    return subprocess.run(
        [sys.executable, str(tmp / "internal/ci/check_deploy_identity_iam.py"), str(tmp)],
        capture_output=True,
        text=True,
    )


def mutate(tmp, old, new):
    path = tmp / BOOTSTRAP
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"mutation anchor not found in {BOOTSTRAP}: {old!r}")
    path.write_text(text.replace(old, new, 1))


def main():
    failures = []

    real = run(scratch())
    if real.returncode != 0:
        failures.append("the real tree was rejected:\n" + real.stdout + real.stderr)

    cases = [
        (
            "an Allow grants an IAM write",
            'sid       = "LocateTheCluster"\n'
            '    effect    = "Allow"\n'
            '    actions   = ["eks:DescribeCluster", "eks:ListClusters"]',
            'sid       = "LocateTheCluster"\n'
            '    effect    = "Allow"\n'
            '    actions   = ["eks:DescribeCluster", "iam:CreateRole"]',
            "IAM-mutating",
        ),
        (
            "a denied IAM-mutation family is narrowed to a read-only action",
            '"iam:Create*",',
            '"iam:Describe*",',
            "no Deny covering",
        ),
        (
            "the read-only observation Allow is widened to a mutation",
            '"iam:SimulatePrincipalPolicy",',
            '"iam:PutRolePolicy",',
            "IAM-mutating",
        ),
    ]

    for label, old, new, reason in cases:
        tmp = scratch()
        mutate(tmp, old, new)
        result = run(tmp)
        output = result.stdout + result.stderr
        if result.returncode == 0:
            failures.append(f"{label}: the guard accepted it")
        elif reason not in output:
            failures.append(f"{label}: rejected for the wrong reason:\n{output}")

    if failures:
        print("test_deploy_identity_iam_check: FAIL", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        sys.exit(1)

    print("test_deploy_identity_iam_check: PASS")


if __name__ == "__main__":
    main()
