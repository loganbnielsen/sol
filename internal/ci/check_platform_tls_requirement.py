import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import tfconfig

MODULE = "platform/cloud/modules/platform/main.tf"
DECLARATION = "cli/lib/cloud/sol_cli_platform_tls.ml"
LIFECYCLE = "cli/lib/cloud/sol_cli_cloud_lifecycle.ml"

ISSUER_ANNOTATION = "cert-manager.io/cluster-issuer"


def block(body, key):
    value = body.get(key, {})
    if isinstance(value, list):
        return value[0] if value else {}
    return value if isinstance(value, dict) else {}


def declared_certificates(root):
    path = root / DECLARATION
    if not path.is_file():
        return None
    text = path.read_text(encoding="utf-8")
    entries = re.findall(
        r'\{\s*certificate\s*=\s*"([^"]+)"\s*;\s*namespace\s*=\s*"([^"]+)"\s*;\s*provenance\s*=\s*"'
        r'((?:[^"\\]|\\.)*)"',
        text,
        re.S,
    )
    return [(certificate, namespace, " ".join(provenance.split())) for certificate, namespace, provenance in entries]


def module_certificates(root):
    path = root / MODULE
    found = tfconfig.resources(path)
    namespaces = {}
    for resource in found:
        if resource.type != "kubernetes_namespace":
            continue
        namespaces[resource.name] = tfconfig.unquote(block(resource.body, "metadata").get("name", ""))
    certificates = {}
    for resource in found:
        if resource.type != "kubernetes_ingress_v1":
            continue
        metadata = block(resource.body, "metadata")
        annotations = metadata.get("annotations", {})
        if not any(tfconfig.unquote(key) == ISSUER_ANNOTATION for key in annotations):
            continue
        reference = str(metadata.get("namespace", ""))
        match = re.search(r"kubernetes_namespace\.([A-Za-z0-9_]+)", reference)
        namespace = namespaces.get(match.group(1), reference) if match else reference
        for tls in tfconfig.blocks(block(resource.body, "spec"), "tls"):
            secret = tfconfig.unquote(tls.get("secret_name", ""))
            certificates[secret] = namespace
    return certificates


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    problems = []

    declared = declared_certificates(root)
    if declared is None:
        sys.exit(f"FAIL: missing {DECLARATION}")
    if not declared:
        sys.exit(
            "FAIL: the TLS declaration names no certificate: the platform declares certificates it "
            "cannot serve, and the readiness gate has nothing to wait for (DEC-056)"
        )

    for certificate, namespace, provenance in declared:
        if not provenance:
            problems.append(f"the declared certificate {namespace}/{certificate} states no provenance")
        elif "platform module" not in provenance and "chart" not in provenance:
            problems.append(
                f"the declared certificate {namespace}/{certificate} does not attribute itself to the "
                f"platform module or a chart it installs, and Sol declares no certificate of its own"
            )

    in_module = module_certificates(root)
    if not in_module:
        problems.append(
            f"no ingress in {MODULE} carries the {ISSUER_ANNOTATION} annotation, so the platform declares "
            f"no certificate for the readiness gate to require"
        )
        pass
    for certificate, namespace, _provenance in declared:
        if certificate not in in_module:
            problems.append(
                f"the readiness contract requires {namespace}/{certificate}, which no annotated ingress in "
                f"the platform module declares: the gate would wait for something that never exists"
            )
        elif in_module[certificate] != namespace:
            problems.append(
                f"the readiness contract requires {namespace}/{certificate}, but the platform module "
                f"declares that secret in {in_module[certificate]}"
            )
    for certificate, namespace in sorted(in_module.items()):
        if certificate not in [entry[0] for entry in declared]:
            problems.append(
                f"the platform module declares the certificate {namespace}/{certificate} and Sol requests it "
                f"from cert-manager, but the readiness contract does not require it: the platform could "
                f"report Ready without it (FND-0068, DEC-056)"
            )

    lifecycle = root / LIFECYCLE
    if lifecycle.is_file():
        text = lifecycle.read_text(encoding="utf-8")
        if "Sol_cli_platform_tls.certificates" not in text:
            problems.append(
                "the readiness checks do not derive from Sol_cli_platform_tls.certificates: a hand-written "
                "list drifts from the declaration, which is what the declaration exists to prevent"
            )
    else:
        problems.append(f"missing {LIFECYCLE}")

    for problem in problems:
        print("FAIL: " + problem, file=sys.stderr)
    if problems:
        sys.exit(1)
    print(
        "platform TLS requirement: "
        + ", ".join(f"{namespace}/{certificate}" for certificate, namespace, _ in declared)
        + "; every one is declared by an ingress the platform module annotates, and the readiness gate "
        "requires exactly that set"
    )


main()
