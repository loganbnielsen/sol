#!/usr/bin/env python3
"""Target destruction must not delete project-wide resources.

A target's Terraform state is scoped to that target, but the provider resources a root
declares are not necessarily: the project's default compute service account is shared by
everything in the project, and a target that managed it would delete it for every other
user of the project on destroy. The GCP cluster root reads it instead -- a data source,
which GKE nodes resolve as their identity when the node pool asks for the default -- and
this guard keeps that shape.

Reading a data source and managing a resource are distinguishable in Terraform's state by
`mode`, which is how the distinction was checked: a state entry for
`google_compute_default_service_account.default` is a `data` record and an ordinary destroy
does not touch it. A guard cannot see state, so this one holds the config-side invariant
that makes the state-side fact true.

The class list is deliberately explicit rather than heuristic: a resource is project-wide
here because it is documented as shared, not because its name looks shared.
"""
import re
import sys
from pathlib import Path

NAME = "check_project_shared_resources"

PROJECT_WIDE = {
    "google_compute_default_service_account": (
        "the project's default compute service account is shared by everything in the project"
    ),
}

ROOTS = ["platform/cloud/gcp/cluster", "platform/cloud/aws/cluster"]


def text_of_any_root(root):
    parts = []
    for relative in ROOTS:
        directory = root / relative
        if directory.exists():
            parts.extend(tf.read_text() for tf in sorted(directory.glob("*.tf")))
    return "\n".join(parts)
RESOURCE = re.compile(r'^resource\s+"(?P<type>[a-z0-9_]+)"\s+"(?P<name>[a-z0-9_]+)"', re.M)
REMOVED = re.compile(
    r"removed\s*\{\s*from\s*=\s*(?P<address>[a-z0-9_]+\.[a-z0-9_]+)\s*"
    r"lifecycle\s*\{\s*destroy\s*=\s*false\s*\}",
    re.S,
)


def main(argv):
    root = Path(argv[1]) if len(argv) > 1 else Path(".")
    problems = []
    declared = {}
    relinquished = set()
    for relative in ROOTS:
        directory = root / relative
        if not directory.exists():
            continue
        for tf in sorted(directory.glob("*.tf")):
            text = tf.read_text()
            for match in RESOURCE.finditer(text):
                declared[f'{match.group("type")}.{match.group("name")}'] = relative
            for match in REMOVED.finditer(text):
                relinquished.add(match.group("address"))
    for address, where in sorted(declared.items()):
        resource_type = address.split(".")[0]
        reason = PROJECT_WIDE.get(resource_type)
        if reason is None:
            continue
        problems.append(
            f"{where} declares a managed resource for {address}: {reason}, so a target's "
            "destroy would delete a resource that is not that target's to delete. Read it "
            "with a data source instead, or relinquish it with `removed { lifecycle { "
            "destroy = false } }`."
        )
    for resource_type, reason in sorted(PROJECT_WIDE.items()):
        if re.search(rf'^data\s+"{resource_type}"', text_of_any_root(root), re.M) is None:
            problems.append(
                f"{reason}, and no root reads it: Sol needs its email to grant the node "
                f"identity registry access, so it must be read as a data source rather than "
                "managed as a resource."
            )
    if problems:
        for problem in problems:
            print(f"{NAME}: {problem}", file=sys.stderr)
        return 1
    print(
        f"{NAME}: {len(declared)} declared resource(s) checked; no target manages a project-wide "
        "resource, and each is read as a data source"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
