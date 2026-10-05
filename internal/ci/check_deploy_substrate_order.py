#!/usr/bin/env python3
"""A deploy establishes a namespace's scoped RBAC before it touches a manifest there (FND-0072).

The invariant: before Sol performs a server-side dry-run or any other application mutation in
namespace N using the deploy identity, N and the scoped deployment RBAC that identity needs must
already exist. Sol establishes both together in `Sol_cli_substrate.ensure`; the defect this guard
fixes was that the only deploy-path call to it sat behind the plan's profile, so a profile-less
target never bootstrapped anything and the first manifest operation was refused by the cluster.

So the guard holds: the substrate step is its own prerequisite, unconditional of the plan's
profile, covering every namespace the plan deploys into, and ordered before any dry-run or apply;
a side-effect-free run must refuse with an explanation rather than discover the gap as a cluster
refusal; and the fix must not be compensated for by widening anybody's authority — neither the
deploy identity beyond the group the platform's own RBAC binds, nor the platform-provisioner
group with namespaced rolebindings it does not have today.
"""

from __future__ import annotations

import pathlib
import re
import sys

DEPLOY_RUN = "cli/lib/deploy/sol_cli_deploy_run.ml"
CMD_DEPLOY = "cli/bin/cmd_deploy.ml"
SUBSTRATE = "cli/lib/deploy/sol_cli_substrate.ml"
PROVISIONER_RBAC = "platform/cloud/modules/platform/platform_provisioner_rbac.tf"
AWS_CLUSTER = "platform/cloud/aws/cluster/main.tf"

BINDINGS = ("sol-deploy", "sol-operator")


def read(root: pathlib.Path, relative: str) -> str:
    path = root / relative
    if not path.exists():
        raise SystemExit(f"cannot read {relative}")

    return path.read_text()


CALL_ENDS = re.compile(r"\n\s*(?:in\b|\)|;;)")


def call_sites(text: str, name: str) -> list[tuple[int, str]]:
    """Every call of `name`, as (index, the argument text that follows it).

    The arguments are read up to the end of the call expression rather than matched as one literal
    string, so reformatting a call across lines cannot make this guard either report a held
    invariant as broken, or read the arguments of the call that follows.
    """
    sites = []
    for match in re.finditer(rf"\b{re.escape(name)}\b", text):
        rest = text[match.end() :]
        terminator = CALL_ENDS.search(rest)
        sites.append((match.start(), rest[: terminator.start() if terminator else len(rest)]))
    return sites


def function_body(text: str, header: str) -> str:
    start = text.index(header)
    end = text.index("\n;;\n", start)

    return text[start:end]


def check(root: pathlib.Path) -> list[str]:
    problems: list[str] = []

    deploy_run = read(root, DEPLOY_RUN)
    try:
        body = function_body(deploy_run, "let substrate_prerequisite ctx")
    except ValueError:
        problems.append(
            f"{DEPLOY_RUN}: there is no substrate_prerequisite, so nothing guarantees a "
            "namespace and its scoped RBAC exist before the deploy touches a manifest there"
        )
        body = ""

    if body:
        if "profile" in body:
            problems.append(
                f"{DEPLOY_RUN}: substrate_prerequisite consults the plan's profile, which is "
                "exactly the defect: a profile-less target then never bootstraps its namespaces"
            )
        if "Sol_cli_substrate.namespaces plan" not in body:
            problems.append(
                f"{DEPLOY_RUN}: substrate_prerequisite does not derive its namespaces from the "
                "plan, so it cannot cover every namespace the deploy is about to enter"
            )
        if "Sol_cli_substrate.ensure" not in body:
            problems.append(
                f"{DEPLOY_RUN}: substrate_prerequisite never establishes anything, so a live "
                "deploy into a fresh namespace would be refused by the cluster"
            )
        if "Sol_cli_substrate.established" not in body:
            problems.append(
                f"{DEPLOY_RUN}: substrate_prerequisite has no side-effect-free path, so a "
                "dry-run would discover a missing prerequisite as a cluster refusal"
            )

    try:
        mutation_owner = function_body(deploy_run, "let apply\n")
    except ValueError:
        problems.append(
            f"{DEPLOY_RUN}: there is no cloud mutation owner to establish the plan's "
            "substrate before it takes the boundary lease"
        )
        mutation_owner = ""

    if mutation_owner and "substrate_prerequisite ctx ~plan ~live:true" not in mutation_owner:
        problems.append(
            f"{DEPLOY_RUN}: the cloud mutation owner does not establish the plan's "
            "substrate with the live check before it acquires the boundary lease"
        )

    try:
        offline_owner = function_body(deploy_run, "let run_offline")
    except ValueError:
        problems.append(
            f"{DEPLOY_RUN}: there is no side-effect-free owner to check the substrate"
        )
        offline_owner = ""

    if offline_owner:
        dry = offline_owner.find("substrate_prerequisite ctx ~plan ~live:false")
        run = offline_owner.find("run_plan_result")
        if dry == -1:
            problems.append(
                f"{DEPLOY_RUN}: the side-effect-free owner has no substrate check, so a "
                "dry-run would discover a missing prerequisite as a cluster refusal"
            )
        elif run != -1 and dry > run:
            problems.append(
                f"{DEPLOY_RUN}: the side-effect-free owner executes before it checks the "
                "substrate, which is the ordering this guard exists to keep"
            )

    substrate = read(root, SUBSTRATE)
    try:
        established = function_body(substrate, "let established")
    except ValueError:
        problems.append(f"{SUBSTRATE}: there is no established check to refuse a dry-run with")
        established = ""

    if established:
        for binding in BINDINGS:
            if binding not in established:
                problems.append(
                    f"{SUBSTRATE}: established does not check for the {binding} RoleBinding, so "
                    "a namespace could satisfy it while the deploy identity still has no "
                    "scoped authority there"
                )
        if '~resource:"namespace"' not in established:
            problems.append(
                f"{SUBSTRATE}: established does not check the namespace itself, so a missing "
                "namespace would be reported as a missing binding"
            )

    provisioner = read(root, PROVISIONER_RBAC)
    if '"rolebindings"' in provisioner:
        problems.append(
            f"{PROVISIONER_RBAC}: the platform provisioner role now grants namespaced "
            "rolebindings, which is widening the platform identity instead of entering the "
            "namespace as the deploy identity"
        )

    cluster = read(root, AWS_CLUSTER)
    if "platform_cluster_access" not in cluster:
        problems.append(
            f"{AWS_CLUSTER}: there is no platform cluster-access entry, so the platform "
            "lifecycle identity the row verified cannot be identified here"
        )
    else:
        after = cluster[cluster.index("platform_cluster_access") :]
        marker = "kubernetes_groups = ["
        if marker not in after:
            problems.append(
                f"{AWS_CLUSTER}: the platform cluster-access entry declares no kubernetes "
                "groups, so which group the deploy identity holds is not readable here"
            )
        else:
            start = after.index(marker) + len(marker)
            groups = after[start : after.index("]", start)]
            if "sol:deployers" in groups:
                problems.append(
                    f"{AWS_CLUSTER}: the platform cluster-access entry carries the deployers "
                    "group, so the two identities are no longer separated"
                )

    return problems


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    try:
        problems = check(root)
    except SystemExit as error:
        print(f"check_deploy_substrate_order: {error}")
        return 1

    if problems:
        print("check_deploy_substrate_order: the deploy prerequisite is not guaranteed:")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print(
        "check_deploy_substrate_order: the substrate step is profile-independent, covers the "
        "plan's namespaces, is established by the cloud mutation owner before its lease and "
        "checked by the side-effect-free owner before execution, refuses with an explanation, "
        "and widens nobody's authority"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
