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
DOCUMENTED_TAXONOMY = ["workspace", "env", "domain", "service", "primitive", "release"]
DEV_TAXONOMY = re.compile(r"~taxonomy_labels:\[(.*?)\]", re.S)


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
    for problem in problems:
        print(f"guardrail: {problem}", file=sys.stderr)
    if problems:
        sys.exit(1)
    print("guardrail: no migrated platform-component keys found duplicated inline in the local platform or main.tf.")
    print("guardrail: the cloud and local Alloy log-promotion taxonomies match and carry all six labels.")


main()
