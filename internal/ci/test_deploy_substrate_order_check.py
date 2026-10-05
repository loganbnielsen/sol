#!/usr/bin/env python3
"""Mutation test for check_deploy_substrate_order.

Every case is a way the FND-0072 invariant can break again: the substrate step gated on the
profile (the actual defect), dropped, emptied of its ensure, decoupled from the plan's namespaces,
called after the dry-run or the apply, given no side-effect-free refusal, checking only the
namespace or only one of the two bindings, or compensated for by widening the platform
provisioner or the cluster-access entry. Each must be rejected for its own reason.
"""

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "internal/ci/check_deploy_substrate_order.py"
COPIED = [
    "cli/lib/deploy/sol_cli_deploy_run.ml",
    "cli/lib/deploy/sol_cli_substrate.ml",
    "cli/bin/cmd_deploy.ml",
    "platform/cloud/modules/platform/platform_provisioner_rbac.tf",
    "platform/cloud/aws/cluster/main.tf",
]


def scratch():
    tmp = Path(tempfile.mkdtemp())
    for relative in COPIED:
        target = tmp / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / relative, target)
    guard_target = tmp / "internal/ci/check_deploy_substrate_order.py"
    guard_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(GUARD, guard_target)
    return tmp


def run(tmp):
    return subprocess.run(
        [sys.executable, str(tmp / "internal/ci/check_deploy_substrate_order.py"), str(tmp)],
        capture_output=True,
        text=True,
    )


def mutate(tmp, relative, old, new):
    path = tmp / relative
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"mutation anchor not found in {relative}: {old!r}")
    path.write_text(text.replace(old, new, 1))


def mutate_live_call(tmp, old, new):
    """The cloud mutation owner stops asking for the live substrate check.

    The call is located by its shape rather than by one spelling of it, so reformatting the call
    across lines does not make this case mutate something else or nothing at all.
    """
    path = tmp / "cli/lib/deploy/sol_cli_deploy_run.ml"
    text = path.read_text()
    pattern = re.compile(r"substrate_prerequisite ctx ~plan " + re.escape(old))
    if not pattern.search(text):
        raise SystemExit(f"mutation anchor not found in cli/lib/deploy/sol_cli_deploy_run.ml: {old!r}")
    path.write_text(pattern.sub(lambda match: match.group(0).replace(old, new), text, count=1))


def main():
    failures = []

    result = run(scratch())
    if result.returncode != 0:
        failures.append("the real tree was rejected:\n" + result.stdout + result.stderr)

    cases = []

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/deploy/sol_cli_deploy_run.ml",
        "let substrate_prerequisite ctx ~plan ~live =",
        "let substrate_prerequisite ctx ~plan ~live =\n  match plan.Sol_cli_deployment_plan.profile with None -> Ok () | Some _ ->",
    )
    cases.append(("substrate-gated-on-the-profile", tmp, "consults the plan's profile"))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/deploy/sol_cli_deploy_run.ml",
        "let substrate_prerequisite ctx ~plan ~live =",
        "let substrate_prerequisite_renamed ctx ~plan ~live =",
    )
    cases.append(("substrate-step-dropped", tmp, "no substrate_prerequisite"))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/deploy/sol_cli_deploy_run.ml",
        "Sol_cli_substrate.ensure\n      ~ctx:ctx.execution.cluster\n      ~namespaces\n",
        "",
    )
    cases.append(("live-path-never-establishes", tmp, "never establishes anything"))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/deploy/sol_cli_deploy_run.ml",
        "  let namespaces = Sol_cli_substrate.namespaces plan in",
        "  let namespaces = [ \"pluto-payments\" ] in",
    )
    cases.append(("namespaces-not-from-the-plan", tmp, "does not derive its namespaces from the plan"))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/deploy/sol_cli_deploy_run.ml",
        "Sol_cli_substrate.established ~ctx:ctx.execution.cluster ~namespaces",
        "Ok ()",
    )
    cases.append(("no-side-effect-free-refusal", tmp, "no side-effect-free path"))

    tmp = scratch()
    mutate_live_call(tmp, "~live:true", "~live:false")
    cases.append(("live-path-loses-its-live-check", tmp, "does not establish the plan's substrate"))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/deploy/sol_cli_substrate.ml",
        '          [ "sol-deploy"; "sol-operator" ]',
        '          [ "sol-operator" ]',
    )
    cases.append(("deploy-binding-not-checked", tmp, "does not check for the sol-deploy RoleBinding"))

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/deploy/sol_cli_substrate.ml",
        '      Sol_cli_kubectl.get ~ctx ~resource:"namespace" ~name:ns ~namespace:"" ~output:"name"',
        '      Sol_cli_kubectl.get ~ctx ~resource:"serviceaccount" ~name:ns ~namespace:"" ~output:"name"',
    )
    cases.append(("namespace-check-rewritten", tmp, "does not check the namespace itself"))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/modules/platform/platform_provisioner_rbac.tf",
        '''    resources  = ["clusterroles", "clusterrolebindings"]''',
        '''    resources  = ["clusterroles", "clusterrolebindings", "rolebindings"]''',
    )
    cases.append(("provisioner-widened", tmp, "widening the platform identity"))

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
        print("test_deploy_substrate_order_check: FAILED")
        for failure in failures:
            print(f"  {failure}")
        return 1

    print(
        "test_deploy_substrate_order_check: the guard accepts the real tree and rejects "
        f"{len(cases)} mutations for their own reasons"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
