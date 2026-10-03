import json
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is not installed: pip install -r internal/ci/requirements.txt")

MUTATING = {"update", "patch", "delete", "deletecollection", "*"}
POLICY_DOCUMENT = re.compile(r'--policy-document\s+"((?:[^"\\]|\\.)*)"')
CLUSTER_ARN = re.compile(r'^cluster_arn="arn:aws:eks:\$\{region\}:\$\{account\}:cluster/\$\{cluster\}"$', re.M)


def fail(message):
    sys.exit(f"check_qualification_transport: {message}")


def git_root():
    out = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return Path(out.stdout.strip() or ".")


def check_establishment_script(step):
    text = step.read_text(encoding="utf-8")
    if "disassociate-access-policy" in text:
        fail(
            "the establishment script closes its window by disassociating the admin policy, "
            "which FND-0021 measured to be reported complete while the authorizer still "
            "granted cluster-admin"
        )
    documents = POLICY_DOCUMENT.findall(text)
    if len(documents) != 1:
        fail(
            f"the establishment script declares {len(documents)} inline role policies; the "
            "transport principal's AWS authority must be one policy this check can read"
        )
    policy = json.loads(documents[0].replace('\\"', '"'))
    statements = policy.get("Statement", [])
    if len(statements) != 1:
        fail(f"the transport role's inline policy has {len(statements)} statements, not one")
    statement = statements[0]
    actions = statement.get("Action")
    if actions != "eks:DescribeCluster":
        fail(
            f"the transport role's inline policy grants '{actions}'; obtaining a kubeconfig "
            "needs eks:DescribeCluster and nothing else"
        )
    resource = statement.get("Resource", "")
    if "*" in resource or resource != "${cluster_arn}":
        fail(
            f"the transport role's inline policy is scoped to '{resource}', which is not the "
            "one cluster this transport reaches"
        )
    if not CLUSTER_ARN.search(text):
        fail("the establishment script does not build the cluster's ARN, so the policy's scope is unknown")


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else git_root()
    transport = root / "internal/qualification/transport/transport.yaml"
    step = root / "internal/qualification/transport/establish.sh"
    config = root / "cli/lib/workspace/sol_cli_config.ml"
    for f in (transport, step, config):
        if not f.is_file():
            fail(f"missing {f}")
    with open(transport, encoding="utf-8") as f:
        documents = [d for d in yaml.safe_load_all(f) if d]
    rules = [
        (sorted(rule.get("resources", [])), sorted(rule.get("verbs", [])))
        for d in documents
        for rule in d.get("rules", [])
    ]
    resources = sorted({r for resources, _ in rules for r in resources})
    if resources != ["pods", "pods/portforward", "services"]:
        fail(f"the qualification transport's resource set changed: '{' '.join(resources)} '")
    by_resources = dict((tuple(resources), verbs) for resources, verbs in rules)
    pod_rule = by_resources.get(("pods", "services"), [])
    fwd_rule = by_resources.get(("pods/portforward",), [])
    if pod_rule != ["get", "list"]:
        fail(f"the addressing rule's verbs changed: '{' '.join(pod_rule)} ' (expected get, list)")
    if fwd_rule != ["create"]:
        fail(f"the transport rule's verbs changed: '{' '.join(fwd_rule)} ' (expected create)")
    if any(set(verbs) & MUTATING for _, verbs in rules):
        fail("the qualification transport grants a mutating verb")
    for directory in sorted(p for p in (root / "platform/cloud").glob("*/*") if p.is_dir()):
        for path in directory.rglob("*"):
            if path.is_file() and re.search(r"sol:qualifiers|sol-qualifier-transport", path.read_text(errors="replace")):
                fail(f"a production Terraform root references the qualification transport: {directory}/")
    if re.search(r"qualifier", config.read_text(), re.I):
        fail(
            "the target schema names a qualifier principal; qualification scaffolding must not enter the "
            "customer-facing contract"
        )
    lifecycle = root / "cli/lib/cloud/sol_cli_cloud_lifecycle.ml"
    if lifecycle.is_file() and "transport.yaml" in lifecycle.read_text():
        fail("Sol's lifecycle applies the qualification transport manifest")
    check_establishment_script(step)
    print(
        "qualification transport: harness-only grant, unreachable from the production path, "
        "and an establishment script whose AWS authority is the one cluster it reaches"
    )


main()
