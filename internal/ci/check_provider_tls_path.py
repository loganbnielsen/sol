import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import tfconfig

PROVIDERS = ("aws", "gcp")

ISSUER = "platform/cloud/modules/platform/cert_manager_issuer.tf"
RELEASE = "platform/cloud/modules/platform/main.tf"
PLATFORM_ROOT = "platform/cloud/{provider}/platform/main.tf"
PLATFORM_VARIABLES = "platform/cloud/{provider}/platform/variables.tf"
CLUSTER_MAIN = "platform/cloud/{provider}/cluster/main.tf"
DRIVER = "cli/lib/cloud/sol_cli_{provider}_cluster.ml"

SOLVER = {"aws": "route53", "gcp": "cloudDNS"}
IDENTITY = {"aws": "cert_manager_irsa_role_arn", "gcp": "cert_manager_workload_identity_sa_email"}
SOLVER_SCOPE = {"aws": "cert_manager_dns01_region", "gcp": "cert_manager_dns01_project"}
ANNOTATION = {"aws": "eks.amazonaws.com/role-arn", "gcp": "iam.gke.io/gcp-service-account"}
RECORD_ACTION = {"aws": "route53:ChangeResourceRecordSets", "gcp": "dns.resourceRecordSets.create"}

LIFTED_GATE = "cannot yet wire"


def text(root, relative):
    path = root / relative
    return path.read_text(encoding="utf-8") if path.is_file() else None


def resources(root, relative, kinds=("resource", "data")):
    path = root / relative
    return tfconfig.resources(path, kinds=kinds) if path.is_file() else []


def module_call(platform_root):
    start = platform_root.find('module "platform"')
    if start < 0:
        return ""
    rest = platform_root[start:]
    end = rest.find("\n}")
    return rest[: end if end > 0 else len(rest)]


def as_list(value):
    if isinstance(value, list):
        return value
    return [value]


def aws_cluster_problems(root):
    statements = []
    for data in resources(root, CLUSTER_MAIN.format(provider="aws")):
        if data.type == "aws_iam_policy_document" and data.name == "cert_manager":
            statements.extend(tfconfig.blocks(data.body, "statement"))
    if not statements:
        return [
            "the AWS cluster root declares no aws_iam_policy_document.cert_manager: cert-manager has no "
            "provider-native DNS permission set"
        ]
    problems = []
    record = [
        statement
        for statement in statements
        if RECORD_ACTION["aws"] in [tfconfig.unquote(a) for a in as_list(statement.get("actions", []))]
    ]
    if not record:
        problems.append(
            f"the AWS cert-manager policy no longer grants {RECORD_ACTION['aws']}: nothing lets a "
            f"challenge be written"
        )
    for statement in record:
        scoped = [tfconfig.unquote(r) for r in as_list(statement.get("resources", []))]
        if scoped == ["*"]:
            problems.append(
                f"the AWS cert-manager policy grants {RECORD_ACTION['aws']} on every hosted zone (\"*\"): "
                f"record authority is scoped to the workspace's zone, and widening it is a security "
                f"change, not a refactor"
            )
    return problems


def gcp_cluster_problems(root):
    found = resources(root, CLUSTER_MAIN.format(provider="gcp"))
    problems = []
    if not [
        r
        for r in found
        if r.type == "google_service_account" and "cert-manager" in str(r.body.get("account_id", ""))
    ]:
        problems.append(
            "the GCP cluster root declares no cert-manager service account: Workload Identity has no "
            "identity to bind (DEC-055)"
        )
    if not [
        r
        for r in found
        if r.type == "google_project_iam_custom_role"
        and RECORD_ACTION["gcp"] in str(r.body.get("permissions", ""))
    ]:
        problems.append(
            f"the GCP cluster root declares no custom role carrying {RECORD_ACTION['gcp']}: cert-manager "
            f"cannot present a challenge"
        )
    if not [
        r
        for r in found
        if r.type == "google_dns_managed_zone_iam_member"
        and "cert_manager" in str(r.body.get("member", ""))
    ]:
        problems.append(
            "the GCP cluster root binds no cert-manager role on the managed zone: record authority is not "
            "scoped to the workspace's own zone"
        )
    if not [
        r
        for r in found
        if r.type == "google_service_account_iam_member"
        and tfconfig.unquote(r.body.get("role", "")) == "roles/iam.workloadIdentityUser"
        and "cert-manager/cert-manager" in str(r.body.get("member", ""))
    ]:
        problems.append(
            "the GCP cluster root binds no roles/iam.workloadIdentityUser for "
            "serviceAccount:<project>.svc.id.goog[cert-manager/cert-manager]: the cert-manager pod cannot "
            "impersonate the service account that holds the DNS permissions"
        )
    cluster = next((r for r in found if r.type == "google_container_cluster"), None)
    pool = next((r for r in found if r.type == "google_container_node_pool"), None)
    if cluster is None or not tfconfig.blocks(cluster.body, "workload_identity_config"):
        problems.append(
            "the GCP cluster declares no workload_identity_config: the Workload Identity pool the plugin "
            "certificates are issued from does not exist, so every iam.gke.io/gcp-service-account "
            "annotation in the platform is dead (GKE serves node credentials instead)"
        )
    if pool is None or not [
        block
        for block in tfconfig.blocks(pool.body, "node_config")
        if any(
            tfconfig.unquote(mode) == "GKE_METADATA"
            for config in tfconfig.blocks(block, "workload_metadata_config")
            for mode in tfconfig.attributes(config, "mode")
        )
    ]:
        problems.append(
            "the GCP node pool runs with the node metadata server (no GKE_METADATA workload metadata "
            "config), so a pod annotated with iam.gke.io/gcp-service-account still receives the node's "
            "identity rather than the service account's"
        )
    if not [r for r in found if r.type == "google_dns_managed_zone"]:
        problems.append(
            "the GCP cluster root names no Cloud DNS managed zone: the record binding has no zone to scope to"
        )
    return problems


def provider_problems(root, provider):
    problems = []
    platform_root = text(root, PLATFORM_ROOT.format(provider=provider))
    if platform_root is None:
        return [f"missing {PLATFORM_ROOT.format(provider=provider)}"]
    call = module_call(platform_root)
    for input_name in (IDENTITY[provider], SOLVER_SCOPE[provider]):
        if input_name not in call:
            problems.append(
                f"the {provider} platform root does not pass {input_name} to the shared platform module: "
                f"the module selects its DNS-01 solver and identity per provider, so the provider that "
                f"owns the value has to supply it"
            )
    variables_path = root / PLATFORM_VARIABLES.format(provider=provider)
    if not variables_path.is_file():
        return problems + [f"missing {variables_path}"]
    variables = tfconfig.variables(variables_path)
    if provider == "gcp":
        if IDENTITY["gcp"] not in variables:
            problems.append(
                "the GCP platform root does not declare cert_manager_workload_identity_sa_email: the cloud "
                "root's cert-manager identity has nowhere to land"
            )
        if "cert_manager_dns01_project" not in variables:
            problems.append(
                "the GCP platform root does not declare cert_manager_dns01_project: the solver cannot name "
                "the project whose zone it writes into"
            )
        problems.extend(gcp_cluster_problems(root))
    else:
        problems.extend(aws_cluster_problems(root))
    return problems


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    problems = []

    needed = [ISSUER, RELEASE]
    for provider in PROVIDERS:
        needed.extend(
            [
                PLATFORM_ROOT.format(provider=provider),
                PLATFORM_VARIABLES.format(provider=provider),
                CLUSTER_MAIN.format(provider=provider),
            ]
        )
    unreadable = []
    for relative in needed:
        path = root / relative
        if not path.is_file():
            unreadable.append(f"missing {relative}")
            continue
        try:
            tfconfig.load(path)
        except Exception as error:
            unreadable.append(f"{relative} does not parse as HCL: {error}")
    if unreadable:
        for problem in unreadable:
            print("FAIL: " + problem, file=sys.stderr)
        sys.exit(1)

    issuer = text(root, ISSUER)
    release = text(root, RELEASE)

    for provider in PROVIDERS:
        if SOLVER[provider] not in issuer:
            problems.append(
                f"the shared platform module declares no {SOLVER[provider]} DNS-01 solver: provider "
                f"{provider} has no certificate path (DEC-055)"
            )
        if f"var.{IDENTITY[provider]}" not in issuer:
            problems.append(
                f"the shared platform module declares no {IDENTITY[provider]} input: provider {provider} "
                f"cannot supply the identity its solver authenticates with"
            )
        if f"var.{SOLVER_SCOPE[provider]}" not in issuer:
            problems.append(
                f"the {SOLVER[provider]} solver does not take its scope from {SOLVER_SCOPE[provider]}: the "
                f"provider root owns that value, and a solver that does not read it writes into whatever "
                f"scope its credentials happen to be in"
            )
        if ANNOTATION[provider] not in issuer and ANNOTATION[provider] not in release:
            problems.append(
                f"nothing wires the {provider} identity annotation {ANNOTATION[provider]} onto the "
                f"cert-manager pod: the provider-native identity is declared but unreachable"
            )
    issuers = [r for r in resources(root, ISSUER) if r.type == "kubernetes_manifest"]
    if len(issuers) < 2:
        problems.append(
            "the module no longer declares both the staging and the production ClusterIssuer: cert-manager "
            "has no issuer to request against"
        )
    for issuer_resource in issuers:
        if "cert_manager_dns01_solver" not in str(issuer_resource.body):
            problems.append(
                f"ClusterIssuer {issuer_resource.name} does not take its solvers from the provider-selected "
                f"solver: the solver is then fixed at declaration time and one provider's challenges run "
                f"against the other provider's API (FND-0067)"
            )
    if "cloudDNS" not in issuer or "route53" not in issuer:
        problems.append(
            "the shared module no longer selects its DNS-01 solver by provider: both cloudDNS and route53 "
            "must be reachable, chosen from var.cloud_provider"
        )
    if issuer.count("precondition") < 2 or issuer.count('local.cert_manager_identity != ""') < 2:
        problems.append(
            "the ClusterIssuers do not both refuse an empty provider identity: an empty identity must fail "
            "closed rather than deploy a solver that runs without credentials (FND-0067)"
        )
    if "cert_manager_identity_annotation" not in release:
        problems.append(
            "the cert-manager release does not set its service-account annotation from the provider's "
            "identity: the pod never assumes the identity the solver needs"
        )

    for provider in PROVIDERS:
        problems.extend(provider_problems(root, provider))

    for provider in PROVIDERS:
        driver = text(root, DRIVER.format(provider=provider))
        if driver is None:
            problems.append(f"missing {DRIVER.format(provider=provider)}")
            continue
        if LIFTED_GATE in driver:
            problems.append(
                f"the {provider} driver still refuses a target that declares cluster_issuer: that gate "
                f"exists to be lifted once the issuer path is wired, and DEC-055 wired it"
            )
        if provider == "gcp" and "cert_manager_workload_identity_sa_email" not in driver:
            problems.append(
                "the GCP driver does not read the cluster's cert-manager identity out of the cloud root's "
                "outputs, so a GCP target with cluster_issuer would install issuers with no identity"
            )

    for problem in problems:
        print("FAIL: " + problem, file=sys.stderr)
    if problems:
        sys.exit(1)
    solvers = ", ".join(f"{provider} -> dns01.{SOLVER[provider]}" for provider in PROVIDERS)
    print(
        "provider TLS path: "
        + solvers
        + "; each provider's root supplies its solver scope and identity, each cluster root owns a "
        "least-privilege DNS permission set bound to the workspace's zone, the cert-manager pod carries "
        "the provider's identity annotation, an empty identity fails closed, and no driver refuses a "
        "target that declares cluster_issuer"
    )


main()
