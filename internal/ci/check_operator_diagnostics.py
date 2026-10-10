import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import tfconfig

MUTATING = {"create", "update", "patch", "delete", "deletecollection"}
INTERACTIVE = {"pods/exec", "pods/portforward", "pods/attach"}
CANONICAL = {"ns": "namespaces", "svc": "services", "cronjob": "cronjobs", "deployment": "deployments"}


def fail(message):
    sys.exit(f"check_operator_diagnostics: {message}")


def git_root():
    out = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return Path(out.stdout.strip() or ".")


def object_after(text, start):
    open_at = text.find("{", start)
    if open_at < 0:
        return None
    depth = 0
    for i in range(open_at, len(text)):
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        if depth == 0:
            return text[open_at:i + 1]
    return None


def operator_entry(aws_main):
    for module in tfconfig.modules(aws_main):
        if module.name != "eks":
            continue
        text = str(module.body.get("access_entries", ""))
        guard = re.search(r'var\.operator_role_arn\s*==\s*""\s*\?\s*\{\}\s*:', text)
        if not guard:
            return None
        entry = re.compile(r"operator\s*=\s*\{").search(text, guard.end())
        return object_after(text, entry.start()) if entry else None
    return None


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else git_root()
    role = root / "platform/cloud/modules/platform/platform_operator_rbac.tf"
    aws_main = root / "platform/cloud/aws/cluster/main.tf"
    aws_vars = root / "platform/cloud/aws/cluster/variables.tf"
    rbac_doc = root / "cli/lib/workspace/sol_cli_manifest_yaml.ml"
    substrate = root / "cli/lib/deploy/sol_cli_substrate.ml"
    for f in (role, aws_main, aws_vars, rbac_doc, substrate):
        if not f.is_file():
            fail(f"missing {f}")
    rules = [rule for r in tfconfig.resources(role, kinds=("resource",)) for rule in tfconfig.blocks(r.body, "rule")]
    verbs = {tfconfig.unquote(v) for rule in rules for v in rule.get("verbs", [])}
    granted = {tfconfig.unquote(v) for rule in rules for v in rule.get("resources", [])}
    if verbs & MUTATING:
        fail("the operator's role grants a mutating verb; it owns observation only")
    if "*" in verbs:
        fail("the operator's role uses a wildcard verb")
    if "secrets" in granted:
        fail("the operator's role grants secrets: inspection is not diagnosis")
    if granted & INTERACTIVE:
        fail("the operator's role grants interactive debugging; DEC-038 excludes it from the diagnostic surface")
    if "operator_role_arn" not in tfconfig.variables(aws_vars):
        fail("operator_role_arn is not a variable of the AWS root")
    entry = operator_entry(aws_main)
    if not entry:
        fail("no access entry is created for operator_role_arn")
    if "sol:operators" not in entry:
        fail("the operator's access entry does not grant the sol:operators group")
    if "policy_associations" in entry:
        fail(
            "the operator's access entry carries an EKS access policy; the grant must be the read-only "
            "ClusterRole, not a broad managed policy"
        )
    rbac_text = rbac_doc.read_text()
    if "let operator_role_binding_doc" not in rbac_text:
        fail("no operator_role_binding_doc: the diagnostic ClusterRole would never be bound")
    if '~cluster_role:"sol-operator-diagnostics"' not in rbac_text:
        fail("the operator's RoleBinding does not reference sol-operator-diagnostics")
    if '~group:"sol:operators"' not in rbac_text:
        fail("the operator's RoleBinding does not bind the sol:operators group")
    substrate_text = substrate.read_text()
    if "Sol_cli_manifest.operator_role_binding_doc ~ns" not in substrate_text:
        fail("Sol_cli_substrate.ensure never applies the operator binding")
    deploy_rbac = root / "platform/cloud/modules/platform/platform_deploy_rbac.tf"
    if not deploy_rbac.is_file():
        fail(f"missing {deploy_rbac}")
    bindable = [
        str(name)
        for r in tfconfig.resources(deploy_rbac, kinds=("resource",))
        for names in tfconfig.attributes(r.body, "resource_names")
        for name in (names if isinstance(names, list) else [names])
    ]
    if not bindable:
        fail("the deploy bootstrap has no enumerated ClusterRole bind allowlist")
    if not any("kubernetes_cluster_role.sol_deploy." in n for n in bindable):
        fail("the deploy bootstrap cannot bind sol-deploy, so its own binding is not creatable")
    if not any("kubernetes_cluster_role.sol_operator_diagnostics." in n for n in bindable):
        fail(
            "the deploy bootstrap cannot bind sol-operator-diagnostics, so the runtime substrate step cannot "
            "create the operator's RoleBinding (a live run failed exactly here)"
        )
    reconcile = re.search(r"^let reconcile_operator_bindings.*?^;;$", substrate_text, re.S | re.M)
    if not reconcile:
        fail("no reconcile_operator_bindings: the grant is still command-scoped")
    if re.search(r"ensure|secret_docs|apply_doc", reconcile.group(0)):
        fail("the operator binding reconciliation is not RBAC-only: it uses the substrate/Secret path")
    if not re.search(r"operator_role_binding_doc|operator_binding_docs", reconcile.group(0)):
        fail(
            "the reconciliation does not produce the operator's RoleBinding through the RBAC-only document producer"
        )
    capabilities = root / "cli/lib/cloud/sol_cli_provider_capabilities.ml"
    if 'provider_field target "operator_role_arn"' not in capabilities.read_text():
        fail("operator_role_arn is declared by the AWS root but never routed to it, so no access entry is created")
    readers = [
        root / "cli/lib/kube/sol_cli_rollout_diagnosis.ml",
    ]
    reads = {m for f in readers for m in re.findall(r'"get"; "([a-z/]+)"', f.read_text())}
    required_diagnosis_reads = {"pods", "events", "cronjob"}
    missing_reads = required_diagnosis_reads - reads
    if missing_reads:
        fail(
            "rollout failure diagnosis no longer reads required Kubernetes resources: "
            + ", ".join(sorted(missing_reads))
        )
    reads = sorted(reads)
    for resource in reads:
        api = CANONICAL.get(resource, resource)
        if api not in granted:
            fail(
                f"the read-only diagnostic path reads '{resource}' ({api}), which the operator's grant does not cover"
            )
    print("deployment diagnostics: read-only grant, wired end to end, covers readiness diagnosis")


main()
