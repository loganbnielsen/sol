import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import tfconfig
from providers import providers

NAME = "check_destroy_completeness"


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    try:
        names = providers(root)
    except (RuntimeError, OSError) as e:
        print(f"sol_providers: {e}", file=sys.stderr)
        sys.exit(f"{NAME}: could not read the provider list")
    target_roots = [
        f"platform/cloud/{p}/cluster" for p in names if (root / f"platform/cloud/{p}/cluster").is_dir()
    ]
    if not target_roots:
        sys.exit(
            f"{NAME}: no provider has a cluster root under '{root}/platform/cloud'; "
            "a check of nothing is not a pass."
        )
    capabilities = root / "cli/lib/cloud/sol_cli_provider_capabilities.ml"
    capabilities_text = capabilities.read_text() if capabilities.exists() else ""
    problems = []
    checked = 0
    for directory in target_roots:
        provider = directory.split("/")[2]
        residue_path = root / f"cli/lib/cloud/sol_cli_{provider}_destruction.ml"
        residue_text = residue_path.read_text() if residue_path.exists() else ""
        for tf in sorted((root / directory).glob("*.tf")):
            checked += 1
            try:
                found = tfconfig.resources(tf)
            except Exception as e:
                problems.append(f"{tf} could not be parsed as Terraform: {e}")
                continue
            problems += check_resources(found, capabilities_text, residue_text, provider, directory)
    if problems:
        for p in problems:
            print(f"{NAME}: {p}", file=sys.stderr)
        sys.exit(1)
    print(
        f'{NAME}: {checked} terraform file(s) in {len(target_roots)} target root(s); no prevent_destroy '
        'or deletion_policy = "PREVENT", no literal deletion guard, every lifecycle-populated resource '
        "removable, every routed guard liftable by the Destroy policy, every relinquished deletion "
        "classified and covered by a residue probe, and every GCS bucket's soft delete declared."
    )


def check_resources(found, capabilities_text, residue_text, provider, directory):
    problems = []
    for r in found:
        for lifecycle in tfconfig.blocks(r.body, "lifecycle"):
            if "prevent_destroy" in lifecycle:
                problems.append(f"{r.where} {r.address} uses prevent_destroy, so a target could never be destroyed (ADR 0004).")
        if r.kind == "resource" and r.type == "aws_ecr_repository" and r.body.get("force_delete") is not True:
            problems.append(f"{r.where} {r.address} is an ECR repository without force_delete = true, so images published by the lifecycle block the teardown.")
        if r.kind == "resource" and r.type in ("aws_s3_bucket", "google_storage_bucket") and r.body.get("force_destroy") is not True:
            problems.append(f"{r.where} {r.address} is an object-storage bucket without force_destroy = true, so platform-written contents block the teardown.")
        if r.kind == "resource" and r.type == "google_storage_bucket":
            policies = tfconfig.blocks(r.body, "soft_delete_policy")
            if not policies:
                problems.append(f"{r.where} {r.address} declares no soft_delete_policy; Cloud Storage would soft-delete and bill its contents after a destroy (INFRA-077).")
            for policy in policies:
                if isinstance(policy.get("retention_duration_seconds"), (int, float)):
                    problems.append(f"{r.where} {r.address} sets its soft-delete retention to a literal; route it through a variable so destroy_retention decides it (INFRA-077).")
        for value in tfconfig.attributes(r.body, "deletion_protection"):
            if isinstance(value, bool):
                problems.append(f"{r.where} {r.address} sets deletion_protection to a literal, which no Destroy policy can override; route it through a variable.")
            guard_var = tfconfig.variable_reference(value)
            if guard_var and not re.search(rf'"{guard_var}",\s*"false"', capabilities_text):
                problems.append(f"{directory} routes {guard_var} through a variable, but no provider's Destroy policy (Sol_cli_provider_capabilities.destroy_guard_vars) lifts it -- so a target Sol provisioned cannot be destroyed through Sol (ADR 0004).")
        for key in ("deletion_policy", "skip_destroy", "skip_delete"):
            for value in tfconfig.attributes(r.body, key):
                problems += classify_deletion(r, key, value, residue_text, provider)
    return list(dict.fromkeys(problems))


def classify_deletion(r, key, value, residue_text, provider):
    literal = tfconfig.unquote(value) if tfconfig.is_string_literal(value) else value
    relinquishes = (key == "deletion_policy" and literal == "ABANDON") or (key != "deletion_policy" and literal is True)
    if relinquishes:
        if f'"{r.address}"' not in residue_text:
            return [f"{r.where} {r.address} relinquishes deletion (Terraform will not delete the remote object), but no residue probe in cli/lib/cloud/sol_cli_{provider}_destruction.ml names it: register one in relinquished_residue_probes (DEC-045)."]
        return []
    if key == "deletion_policy" and literal == "PREVENT":
        return [f'{r.where} {r.address} sets deletion_policy = "PREVENT", which no Destroy policy can lift: a target Sol provisioned could never be destroyed (ADR 0004).']
    if (key == "deletion_policy" and literal == "DELETE") or (key != "deletion_policy" and literal is False):
        return []
    return [f"{r.where} {r.address} sets {key} to '{value}', a deletion semantic this guard cannot classify; declare the value explicitly (and, if it relinquishes the remote object, register its residue probe) so the invariant does not rest on a value the check cannot read."]


main()
