#!/usr/bin/env python3
"""The deploy identity cannot grant itself authority (DEC-062 rule 1).

DEC-062 separates workload cloud authorization from deployment: a fenced
reconciler owns per-unit roles and grants, while `sol deploy` only consumes
established identities and verifies access read-only. The deploy identity
therefore must not hold any IAM-mutating permission at all -- not because a
particular call site is careful, but because the capability would let it grant
itself or a workload anything.

The generated policy in `platform/cloud/aws/bootstrap/main.tf` allows only
read-only IAM visibility (`iam:Get`, `iam:List`, `iam:Simulate`) and denies every
IAM-mutation family; this guard reads that document structurally so a later edit
that widens the deploy identity (an Allow that slips an IAM write in, or a denied
family narrowed away) fails here rather than at a live qualification.
"""

from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))

import tfconfig

BOOTSTRAP = "platform/cloud/aws/bootstrap/main.tf"
DOCUMENT = "data.aws_iam_policy_document.deploy"

READ_ONLY_IAM_PREFIXES = ("iam:Get", "iam:List", "iam:Simulate")

REQUIRED_DENIED_IAM_PREFIXES = (
    "iam:Create",
    "iam:Delete",
    "iam:Put",
    "iam:Attach",
    "iam:Detach",
    "iam:Update",
    "iam:Add",
    "iam:Remove",
    "iam:Set",
    "iam:Tag",
    "iam:Untag",
    "iam:PassRole",
    "iam:Deactivate",
    "iam:Enable",
    "iam:Upload",
    "iam:Resync",
)


def actions_of(statement):
    raw = statement.get("actions", [])
    if isinstance(raw, str):
        raw = [raw]
    return [tfconfig.unquote(action) for action in raw]


def is_iam_action(action):
    return action == "iam:*" or action.startswith("iam:")


def mutates_iam(action):
    if not is_iam_action(action):
        return False
    if action == "iam:*":
        return True
    return not action.startswith(READ_ONLY_IAM_PREFIXES)


def denies_prefix(denied, prefix):
    return any(action == "iam:*" or action == prefix or action.startswith(f"{prefix}*") for action in denied)


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    path = root / BOOTSTRAP
    if not path.exists():
        sys.exit(f"check_deploy_identity_iam: cannot read {BOOTSTRAP}")

    documents = [r for r in tfconfig.resources(path) if r.address == DOCUMENT]
    if not documents:
        sys.exit(f"check_deploy_identity_iam: {BOOTSTRAP} has no {DOCUMENT} policy document")

    problems = []
    denied_iam = set()
    statements = documents[0].body.get("statement", [])
    if isinstance(statements, dict):
        statements = [statements]
    for statement in statements:
        effect = tfconfig.unquote(statement.get("effect", ""))
        granted = actions_of(statement)
        sid = tfconfig.unquote(statement.get("sid", ""))
        if effect == "Allow":
            mutating = [action for action in granted if mutates_iam(action)]
            if mutating:
                problems.append(
                    f"the deploy identity's Allow statement {sid!r} grants "
                    f"IAM-mutating action(s): {', '.join(mutating)}"
                )
        elif effect == "Deny":
            denied_iam.update(action for action in granted if is_iam_action(action))

    for prefix in REQUIRED_DENIED_IAM_PREFIXES:
        if not denies_prefix(denied_iam, prefix):
            problems.append(
                f"the deploy identity's policy has no Deny covering IAM mutation "
                f"'{prefix}*', so a future Allow could grant it authority"
            )

    if problems:
        for problem in problems:
            print(f"check_deploy_identity_iam: {problem}", file=sys.stderr)
        print(
            "check_deploy_identity_iam: DEC-062 rule 1 requires the deploy identity to be "
            "structurally incapable of granting cloud authority",
            file=sys.stderr,
        )
        sys.exit(1)

    print(
        "check_deploy_identity_iam: the deploy identity allows only read-only IAM "
        "visibility and denies every IAM-mutation family"
    )


if __name__ == "__main__":
    main()
