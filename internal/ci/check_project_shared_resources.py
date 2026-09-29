#!/usr/bin/env python3
"""Target destruction must not delete project-wide resources.

A target's Terraform state is scoped to that target, but the provider resources a root
declares are not necessarily: the project's default compute service account is shared by
everything in the project. An older revision of the GCP cluster root *managed* it, so any
state written then holds it, and an ordinary destroy would delete it for every other user
of the project. The current configuration only reads it (a data source), and this guard
keeps that true and keeps the legacy management relinquished without deletion.

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
        if f"{resource_type}.default" in relinquished:
            continue
        problems.append(
            f"{reason}, and states written by an older revision still hold "
            f"{resource_type}.default: the GCP cluster root must relinquish it with "
            "`removed { from = "
            f"{resource_type}.default lifecycle {{ destroy = false }} }}` so a destroy stops "
            "managing it without deleting it."
        )
    if problems:
        for problem in problems:
            print(f"{NAME}: {problem}", file=sys.stderr)
        return 1
    print(
        f"{NAME}: {len(declared)} declared resource(s) checked; no project-wide resource is "
        f"managed by a target, and {len(relinquished)} legacy address(es) are relinquished "
        "without deletion"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
