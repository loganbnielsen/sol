import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import tfconfig

MIGRATED = [
    "deploymentMode",
    "singleBinary.replicas",
    "write.replicas",
    "read.replicas",
    "backend.replicas",
    "gateway.enabled",
    "loki.auth_enabled",
    "loki.commonConfig.replication_factor",
    "loki.storage.type",
    "loki.useTestSchema",
    "sidecar.dashboards.enabled",
    "sidecar.datasources.enabled",
    "pushgateway.enabled",
    "alertmanager.enabled",
    "tls.enabled",
    "config.cluster.auto_create_topics_enabled",
    "auth.database",
]
LOCAL_ONLY = [
    "singleBinary.persistence.enabled",
    "server.persistentVolume.enabled",
    "statefulset.replicas",
    "resources.cpu.cores",
    "auth.postgresPassword",
    "primary.persistence.enabled",
]
LAYERS = {"common", "local", "durable"}

PLATFORM_MAIN = "platform/cloud/modules/platform/main.tf"
DEV_OBSERVABILITY = "cli/lib/local/sol_cli_dev_observability.ml"
MANIFEST = "cli/lib/workspace/sol_cli_manifest_yaml.ml"
FRAMEWORK_OBS = "framework/ocaml/sol-obs/lib/sol_obs.ml"
DEPLOYMENT_RENDER = "cli/lib/deploy/sol_cli_deployment_render.ml"
DOCUMENTED_TAXONOMY = ["workspace", "env", "domain", "service", "primitive", "release"]
DEV_TAXONOMY = re.compile(r"~taxonomy_labels:\[(.*?)\]", re.S)


def ocaml_pair_list(text, name):
    match = re.search(rf"let {name} =\s*\[(.*?)\]\s*;;", text, re.S)
    if match is None:
        return None
    return re.findall(r'"([^"]+)"\s*,\s*"([^"]+)"', match.group(1))


def identity_problems(root):
    problems = []
    documented = sorted(DOCUMENTED_TAXONOMY)
    framework = root / FRAMEWORK_OBS
    manifest = root / MANIFEST
    render = root / DEPLOYMENT_RENDER
    framework_pairs = None
    if not framework.is_file():
        problems.append(f"{FRAMEWORK_OBS} is missing, so the emitted identity vocabulary cannot be checked")
    else:
        framework_pairs = ocaml_pair_list(framework.read_text(encoding="utf-8"), "taxonomy")
        if framework_pairs is None:
            problems.append(
                f'{FRAMEWORK_OBS} no longer declares `let taxonomy = [ "SOL_VAR", "label"; ... ]`'
            )
        else:
            labels = sorted(label for _, label in framework_pairs)
            if labels != documented:
                problems.append(
                    f"the framework's emitted identity labels must be exactly {DOCUMENTED_TAXONOMY}; "
                    f"got {labels} (DEC-064)"
                )
    manifest_pairs = None
    if not manifest.is_file():
        problems.append(f"{MANIFEST} is missing, so the rendered identity vocabulary cannot be checked")
    else:
        manifest_pairs = ocaml_pair_list(
            manifest.read_text(encoding="utf-8"), "observability_identity"
        )
        if manifest_pairs is None:
            problems.append(
                f'{MANIFEST} no longer declares `let observability_identity = [ "label", "SOL_VAR"; ... ]`'
            )
        else:
            labels = sorted(label for label, _ in manifest_pairs)
            if labels != documented:
                problems.append(
                    f"the rendered identity labels must be exactly {DOCUMENTED_TAXONOMY}; "
                    f"got {labels} (DEC-064)"
                )
    if framework_pairs is not None and manifest_pairs is not None:
        framework_env = {label: var for var, label in framework_pairs}
        manifest_env = {label: var for label, var in manifest_pairs}
        if framework_env != manifest_env:
            problems.append(
                "the framework and the manifest must map each identity label to the same environment "
                f"variable; framework={framework_env}, manifest={manifest_env}"
            )
    if not render.is_file():
        problems.append(f"{DEPLOYMENT_RENDER} is missing, so the workload env injection cannot be checked")
    elif "Sol_cli_manifest.identity_env" not in render.read_text(encoding="utf-8"):
        problems.append(
            f"{DEPLOYMENT_RENDER} must render the workload identity through "
            "Sol_cli_manifest.identity_env (DEC-064)"
        )
    return problems


def ocaml_taxonomy(text):
    match = DEV_TAXONOMY.search(text)
    if match is None:
        return None
    return re.findall(r'"([^"]+)"', match.group(1))


def terraform_taxonomy(path):
    data = tfconfig.load(path)
    for block in tfconfig.blocks(data, "locals"):
        if "observability_taxonomy_labels" in block:
            labels = block["observability_taxonomy_labels"]
            return [tfconfig.unquote(value) for value in labels]
    return None


def taxonomy_problems(root):
    problems = []
    main_tf = root / PLATFORM_MAIN
    dev = root / DEV_OBSERVABILITY
    try:
        cloud = terraform_taxonomy(main_tf)
    except Exception as e:
        return [f"{main_tf} could not be parsed for observability_taxonomy_labels: {e}"]
    if cloud is None:
        problems.append(f"{main_tf} no longer declares locals.observability_taxonomy_labels")
    if not dev.is_file():
        problems.append(f"{DEV_OBSERVABILITY} is missing, so the local Alloy mirror cannot be checked")
        return problems
    local = ocaml_taxonomy(dev.read_text(encoding="utf-8"))
    if local is None:
        problems.append(f"{DEV_OBSERVABILITY} no longer declares ~taxonomy_labels:[...]")
    if cloud is not None and local is not None:
        if cloud != local:
            problems.append(
                f"the cloud Alloy taxonomy {cloud} and the local mirror {local} must be identical "
                "(dev mirrors prod, DEC-046)"
            )
        if sorted(cloud) != sorted(DOCUMENTED_TAXONOMY):
            problems.append(
                f"the log-promotion taxonomy must be exactly {DOCUMENTED_TAXONOMY}; got {cloud} "
                "(the six-label identity includes env -- OBS-049)"
            )
    return problems


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[2])
    local_sources = [root / "cli/bin/cmd_local.ml", root / "cli/lib/local/sol_cli_local_platform.ml"]
    main_tf = root / PLATFORM_MAIN
    components_json = root / "platform/shared/components.json"
    problems = []
    for key in MIGRATED:
        for source in local_sources + [main_tf]:
            if source.is_file() and f'"{key}"' in source.read_text():
                problems.append(
                    f'{source} hardcodes "{key}" inline again -- this value belongs in '
                    "platform/shared/components.json (ADR 0001 / CODE_LAYER-005)."
                )
    for key in LOCAL_ONLY:
        for source in local_sources:
            if source.is_file() and f'"{key}"' in source.read_text():
                problems.append(
                    f'{source} hardcodes "{key}" inline again -- this value now comes entirely from the local '
                    "layer of platform/shared/components.json (ADR 0001 / CODE_LAYER-005)."
                )
    try:
        components = json.loads(components_json.read_text())
    except (OSError, ValueError) as e:
        problems.append(f"{components_json} could not be read: {e}")
        components = {}
    bad = [
        f"{name}: {sorted(layers) if isinstance(layers, dict) else type(layers).__name__}"
        for name, layers in sorted(components.items())
        if not isinstance(layers, dict) or set(layers) != LAYERS
    ]
    if bad:
        problems.append(
            f"every component in {components_json} must have exactly the layers common, local, durable "
            "(keyed by profile, never by env, provider or region):\n  " + "\n  ".join(bad)
        )
    problems.extend(taxonomy_problems(root))
    problems.extend(identity_problems(root))
    for problem in problems:
        print(f"guardrail: {problem}", file=sys.stderr)
    if problems:
        sys.exit(1)
    print("guardrail: no migrated platform-component keys found duplicated inline in the local platform or main.tf.")
    print("guardrail: the cloud and local Alloy log-promotion taxonomies match and carry all six labels.")
    print("guardrail: the framework, manifest and workload identity injection carry the same six labels under the same SOL_* names.")


main()
