#!/usr/bin/env python3
import re
import sys
from pathlib import Path

NAME = "check_resource_identity"

EXPECTED_TYPE_RULES = ["kubernetes_", "helm_", "terraform_data", "random_", "null_resource"]

ENTRY = re.compile(r'entry\s+"(?P<address>[a-z0-9_]+\.[a-z0-9_]+)"\s+(?P<ownership>[A-Za-z_]+)')
IMPORT = re.compile(r'~import_identity:\s*(?P<value>"[^"]*"|[^\n;]*)')
TYPE_RULE = re.compile(r'terraform_type\s*=\s*"(?P<value>[^"]*)"')


def registry(path):
    text = path.read_text() if path.exists() else ""
    entries = {}
    for match in ENTRY.finditer(text):
        window = text[match.end() :]
        following = window.find("; entry")
        if following != -1:
            window = window[:following]
        window = window[:400]
        import_match = IMPORT.search(window)
        entries[match.group("address")] = {
            "ownership": match.group("ownership").lower(),
            "import_identity": (import_match.group("value").strip().strip('"') if import_match else ""),
        }
    type_rules = [m.group("value") for m in TYPE_RULE.finditer(text)]
    return entries, type_rules


def root_addresses(root):
    found = []
    for tf in sorted(root.glob("*.tf")):
        text = tf.read_text()
        for match in re.finditer(r'^resource\s+"(?P<type>[a-z0-9_]+)"\s+"(?P<name>[a-z0-9_]+)"', text, re.M):
            found.append(f'{match.group("type")}.{match.group("name")}')
    return found


def main(argv):
    root = Path(argv[1]) if len(argv) > 1 else Path(".")
    registry_path = root / "cli/lib/cloud/sol_cli_resource_identity.ml"
    entries, type_rules = registry(registry_path)
    problems = []
    if not entries:
        problems.append(f"the identity registry could not be read at {registry_path}")
    if sorted(type_rules) != sorted(EXPECTED_TYPE_RULES):
        problems.append(
            "the registry must carry the class-level rules for Terraform-internal and in-cluster "
            f"families: expected {EXPECTED_TYPE_RULES}, read {type_rules}"
        )
    checked = 0
    for provider in ("gcp", "aws"):
        roots = [
            root / f"platform/cloud/{provider}/cluster",
            root / "platform/cloud/modules/platform",
        ]
        for tf_root in roots:
            if not tf_root.exists():
                continue
            for address in root_addresses(tf_root):
                checked += 1
                terraform_type = address.split(".")[0]
                entry = entries.get(address)
                if entry is None:
                    covered = [rule for rule in type_rules if terraform_type.startswith(rule)]
                    if covered:
                        continue
                    problems.append(
                        f"{tf_root} declares {address}, which the identity registry does not "
                        "account for: every directly Terraform-managed resource must declare how it "
                        "is rediscovered at the provider (an entry in sol_cli_resource_identity.ml) "
                        "or fall under a class-level ownership rule (FND-0070)"
                    )
                    continue
                if entry["ownership"] == "direct" and entry["import_identity"] == "":
                    problems.append(
                        f"the registry entry for {address} is Direct, so it must carry an "
                        "~import_identity: the provider identity Sol would import to restore "
                        "Terraform ownership of an unadopted resource (FND-0070)"
                    )
    declared = set()
    for provider in ("gcp", "aws"):
        for tf_root in (
            root / f"platform/cloud/{provider}/cluster",
            root / "platform/cloud/modules/platform",
        ):
            if tf_root.exists():
                declared.update(root_addresses(tf_root))
    for address in sorted(entries):
        if address not in declared:
            problems.append(
                f"the identity registry names {address}, which no provider root or the shared "
                "platform module declares: a stale entry passes off a resource Sol does not have "
                "(FND-0070)"
            )
    if problems:
        for problem in problems:
            print(f"{NAME}: {problem}", file=sys.stderr)
        return 1
    print(
        f"{NAME}: {checked} terraform resource(s) across the provider cluster roots and the shared "
        "platform module all carry an ownership kind, and every directly managed one an import "
        "identity"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
