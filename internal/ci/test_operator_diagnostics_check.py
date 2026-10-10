import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "internal/ci/check_operator_diagnostics.py"
FILES = [
    "platform/cloud/modules/platform/platform_operator_rbac.tf",
    "platform/cloud/aws/cluster/main.tf",
    "platform/cloud/aws/cluster/variables.tf",
    "cli/lib/workspace/sol_cli_manifest_yaml.ml",
    "cli/lib/deploy/sol_cli_substrate.ml",
    "cli/lib/kube/sol_cli_rollout_diagnosis.ml",
    "cli/lib/cloud/sol_cli_provider_capabilities.ml",
    "platform/cloud/modules/platform/platform_deploy_rbac.tf",
]
ROLE = "platform/cloud/modules/platform/platform_operator_rbac.tf"
AWS_MAIN = "platform/cloud/aws/cluster/main.tf"
POD_RESOURCES = 'resources  = ["pods", "pods/log", "services", "events"]'


def replace(path, old, new, every=False):
    def mutate(root):
        text = (root / path).read_text()
        if old not in text:
            sys.exit(f"FAIL: a mutation's anchor no longer matches {path}: {old!r}")
        (root / path).write_text(text.replace(old, new) if every else text.replace(old, new, 1))
    return mutate


def drop_operator_entry(root):
    text = (root / AWS_MAIN).read_text()
    start = text.index("    var.operator_role_arn ==")
    end = text.index("    },\n", text.index('kubernetes_groups = ["sol:operators"]')) + len("    },\n")
    (root / AWS_MAIN).write_text(text[:start] + text[end:])


GROUPS = 'kubernetes_groups = ["sol:operators"]'
CASES = [
    ("a mutating verb", replace(ROLE, '    verbs      = ["get", "list"]', '    verbs      = ["get", "list", "delete"]')),
    ("secrets in the grant", replace(ROLE, POD_RESOURCES, POD_RESOURCES[:-1] + ', "secrets"]')),
    ("pods/portforward", replace(ROLE, POD_RESOURCES, POD_RESOURCES[:-1] + ', "pods/portforward"]')),
    ("a missing access entry", drop_operator_entry),
    ("a managed access policy on the operator entry", replace(
        AWS_MAIN, GROUPS,
        GROUPS + '\n        policy_associations = { view = { policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy" } }')),
    ("a ClusterRole that is never bound", replace(
        "cli/lib/deploy/sol_cli_substrate.ml", "operator_role_binding_doc ~ns", "operator_role_binding_doc_DISABLED ~ns",
        every=True)),
    ("the operator binding pointed at another ClusterRole", replace(
        "cli/lib/workspace/sol_cli_manifest_yaml.ml", '~cluster_role:"sol-operator-diagnostics"', '~cluster_role:"cluster-admin"')),
    ("the operator binding granted to another group", replace(
        "cli/lib/workspace/sol_cli_manifest_yaml.ml", '~group:"sol:operators"', '~group:"system:authenticated"')),
    ("a new read the operator cannot perform", replace(
        "cli/lib/kube/sol_cli_rollout_diagnosis.ml",
        '[ "get"; "pods"; "-n"; ns; "-l"',
        '[ "get"; "configmaps"; "-n"; ns; "-l"')),
    ("a missing Kubernetes permission required for rollout failure diagnosis", replace(
        ROLE,
        POD_RESOURCES,
        '    resources  = ["pods", "pods/log", "services"]')),
    ("an ARN that never reaches the provider root", replace(
        "cli/lib/cloud/sol_cli_provider_capabilities.ml", '(Sol_cli_config.provider_field target "operator_role_arn")', "None")),
    ("an operator RoleBinding the substrate identity cannot bind", replace(
        "platform/cloud/modules/platform/platform_deploy_rbac.tf",
        "      kubernetes_cluster_role.sol_operator_diagnostics.metadata[0].name,\n", "")),
    ("a reconciliation that writes Secrets", replace(
        "cli/lib/deploy/sol_cli_substrate.ml", "  let failures =", "  let _ = secret_docs [] in\n  let failures =")),
]


def seed(scratch):
    root = scratch / "root"
    shutil.rmtree(root, ignore_errors=True)
    for rel in FILES:
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(REPO / rel, root / rel)
    return root


def passes(root):
    return subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)


def main():
    with tempfile.TemporaryDirectory() as scratch:
        run = passes(seed(Path(scratch)))
        if run.returncode != 0:
            sys.exit(f"test_operator_diagnostics: expected the guard to pass, but it failed:\n{run.stderr}")
        for what, mutate in CASES:
            root = seed(Path(scratch))
            mutate(root)
            if passes(root).returncode == 0:
                sys.exit(f"test_operator_diagnostics: the guard accepted {what}")
    print("operator diagnostics check: every guard rejection reproduced")


main()
