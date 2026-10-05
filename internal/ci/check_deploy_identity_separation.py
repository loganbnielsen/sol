#!/usr/bin/env python3
"""The deploy identity and the platform lifecycle identities stay separate (FND-0072, DEC-034).

Two structural guarantees that prerequisite ordering does not cover:

- The steady-state platform provisioner RBAC must not grant namespaced
  `rolebindings`. A workspace deploy enters a namespace with its own scoped RBAC
  (`Sol_cli_substrate.ensure`); widening the provisioner instead would let the platform
  identity mutate namespaced authority it does not hold today.
- The EKS platform cluster-access entry must not carry the deployers group, so the
  identity that provisions the platform is not also a deploy identity.

Prerequisite ordering and substrate establishment are established directly by
`cli/test/inline/test_deploy_run.ml`, not by source positions. This guard no longer
models source layout.
"""

from __future__ import annotations

import pathlib
import sys

PROVISIONER_RBAC = "platform/cloud/modules/platform/platform_provisioner_rbac.tf"
AWS_CLUSTER = "platform/cloud/aws/cluster/main.tf"


def read(root: pathlib.Path, relative: str) -> str:
    path = root / relative
    if not path.exists():
        raise SystemExit(f"cannot read {relative}")

    return path.read_text()


def check(root: pathlib.Path) -> list[str]:
    problems: list[str] = []

    provisioner = read(root, PROVISIONER_RBAC)
    if '"rolebindings"' in provisioner:
        problems.append(
            f"{PROVISIONER_RBAC}: the platform provisioner role now grants namespaced "
            "rolebindings, which widens the platform identity instead of entering the "
            "namespace as the deploy identity"
        )

    cluster = read(root, AWS_CLUSTER)
    if "platform_cluster_access" not in cluster:
        problems.append(
            f"{AWS_CLUSTER}: there is no platform cluster-access entry, so which "
            "Kubernetes group the platform identity holds is not readable here"
        )
    else:
        after = cluster[cluster.index("platform_cluster_access") :]
        marker = "kubernetes_groups = ["
        if marker not in after:
            problems.append(
                f"{AWS_CLUSTER}: the platform cluster-access entry declares no kubernetes "
                "groups, so the two identities are not separated here"
            )
        else:
            start = after.index(marker) + len(marker)
            groups = after[start : after.index("]", start)]
            if "sol:deployers" in groups:
                problems.append(
                    f"{AWS_CLUSTER}: the platform cluster-access entry carries the "
                    "deployers group, so the two identities are no longer separated"
                )

    return problems


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    try:
        problems = check(root)
    except SystemExit as error:
        print(f"check_deploy_identity_separation: {error}")
        return 1

    if problems:
        print("check_deploy_identity_separation: the deploy and platform identities are not separated:")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print(
        "check_deploy_identity_separation: the provisioner grants no namespaced "
        "rolebindings and the platform cluster-access entry carries no deployers group"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
