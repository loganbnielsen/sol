import json
import sys
from pathlib import Path

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


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[2])
    local_sources = [root / "cli/bin/cmd_local.ml", root / "cli/lib/local/sol_cli_local_platform.ml"]
    main_tf = root / "platform/cloud/modules/platform/main.tf"
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
    for problem in problems:
        print(f"guardrail: {problem}", file=sys.stderr)
    if problems:
        sys.exit(1)
    print("guardrail: no migrated platform-component keys found duplicated inline in the local platform or main.tf.")


main()
