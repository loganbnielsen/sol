import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import tfconfig

MACHINES = {
    "gcp": {
        "e2-standard-2": (2, 8),
        "e2-standard-4": (4, 16),
        "e2-standard-8": (8, 32),
        "e2-standard-16": (16, 64),
        "e2-standard-32": (32, 128),
    },
    "aws": {
        "m6i.large": (2, 8),
        "m6i.xlarge": (4, 16),
        "m6i.2xlarge": (8, 32),
        "m6i.4xlarge": (16, 64),
        "t3.medium": (2, 4),
    },
}

DRIVERS = {
    "gcp": (
        "platform/cloud/gcp/cluster/variables.tf",
        "node_machine_type",
        "node_count",
    ),
    "aws": (
        "platform/cloud/aws/cluster/variables.tf",
        "node_instance_types",
        "node_desired_size",
    ),
}

PROFILE = "cli/lib/base/sol_cli_profile.ml"
ENVELOPE_FIELDS = (
    "largest_pod_vcpu",
    "min_vcpu_per_node",
    "min_memory_gib_per_node",
    "platform_vcpu",
    "platform_memory_gib",
)

CHUNKS_CACHE_GIB = 9.6
MEMORY_RESERVED = 0.265
HEADROOM_NODES = 1


def numbers(value):
    if isinstance(value, (int, float)):
        return [float(value)]
    if isinstance(value, list):
        return [number for item in value for number in numbers(item)]
    return []


def names(value):
    if isinstance(value, str):
        return [tfconfig.unquote(value)]
    if isinstance(value, list):
        return [name for item in value for name in names(item)]
    return []


def envelope(profile):
    text = profile.read_text(encoding="utf-8")
    block = re.search(r"let platform_capacity_envelope\s*=\s*\{(.*?)\n\s*\}", text, re.S)
    if block is None:
        return None, [
            f"the profile no longer declares platform_capacity_envelope in {profile.name}: the driver "
            f"defaults are sized from it, so the check cannot run"
        ]
    found = dict(re.findall(r"([a-z_]+)\s*=\s*(\d+)", block.group(1)))
    missing = [field for field in ENVELOPE_FIELDS if field not in found]
    if missing:
        return None, [
            f"platform_capacity_envelope no longer declares {', '.join(missing)}: the field this check "
            f"sizes the drivers against is gone"
        ]
    return {field: int(found[field]) for field in ENVELOPE_FIELDS}, []


def provider_problems(provider, machine, nodes, table, limits):
    problems = []
    shaped = table.get(machine)
    if shaped is None:
        return [
            f"the {provider} driver's default node shape {machine} is not one this check knows: add its "
            f"vCPU and memory to the table, so the profile's own capacity envelope can be fitted to it"
        ]
    vcpu, gib = shaped
    headroom = max(0, nodes - HEADROOM_NODES)
    if vcpu < limits["min_vcpu_per_node"]:
        problems.append(
            f"the {provider} default node shape {machine} has {vcpu} vCPU, below the profile's "
            f"min_vcpu_per_node ({limits['min_vcpu_per_node']}): the drivers must not default to a shape "
            f"the profile itself refuses (FND-0066 -- GCP Attempt 16 installed on 3 x e2-standard-2 and "
            f"stopped with four unschedulable pods)"
        )
    if gib < limits["min_memory_gib_per_node"]:
        problems.append(
            f"the {provider} default node shape {machine} has {gib} GiB, below the profile's "
            f"min_memory_gib_per_node ({limits['min_memory_gib_per_node']})"
        )
    if vcpu < limits["largest_pod_vcpu"]:
        problems.append(
            f"the {provider} default node shape {machine} has {vcpu} vCPU and the profile's "
            f"largest_pod_vcpu is {limits['largest_pod_vcpu']}: a single pod cannot fit a node, so no node "
            f"count can schedule it"
        )
    if headroom * vcpu < limits["platform_vcpu"]:
        problems.append(
            f"the {provider} driver defaults to {nodes} nodes of {machine}, and with {HEADROOM_NODES} held "
            f"back for node-failure headroom that is {headroom * vcpu} vCPU against the profile's "
            f"platform_vcpu ({limits['platform_vcpu']}): the recommended shape is "
            f"{HEADROOM_NODES} more node(s) than this, for exactly this reason"
        )
    if headroom * gib < limits["platform_memory_gib"]:
        problems.append(
            f"the {provider} driver defaults to {nodes} nodes of {machine}, and with {HEADROOM_NODES} held "
            f"back that is {headroom * gib} GiB against the profile's platform_memory_gib "
            f"({limits['platform_memory_gib']})"
        )
    allocatable = gib * (1 - MEMORY_RESERVED)
    if allocatable < CHUNKS_CACHE_GIB:
        problems.append(
            f"the {provider} default node shape {machine} leaves about {allocatable:.2f} GiB allocatable "
            f"per node, and the loki chart's chunks cache requests {CHUNKS_CACHE_GIB:g} GiB -- a size Sol "
            f"does not declare and so inherits from the chart's own defaults (measured live in GCP "
            f"Attempt 16): no node of this shape can ever schedule it, whatever the node count"
        )
    return problems


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    limits, problems = envelope(root / PROFILE)
    if limits is None:
        for problem in problems:
            print("FAIL: " + problem, file=sys.stderr)
        sys.exit(1)

    checked = []
    for provider, (relative, shape_variable, count_variable) in sorted(DRIVERS.items()):
        path = root / relative
        if not path.is_file():
            problems.append(f"missing {path}")
            continue
        driver = tfconfig.variables(path)
        usable = True
        for variable in (shape_variable, count_variable):
            if variable not in driver or "default" not in driver[variable]:
                problems.append(f"the {provider} driver no longer declares a default for {variable}")
                usable = False
        if not usable:
            continue
        for machine in names(driver[shape_variable]["default"]):
            counts = numbers(driver[count_variable]["default"])
            checked.append(f"{provider}:{machine} x {counts[0]:g}" if counts else f"{provider}:{machine}")
            for nodes in counts or [0.0]:
                problems.extend(
                    provider_problems(provider, machine, int(nodes), MACHINES[provider], limits)
                )

    for problem in problems:
        print("FAIL: " + problem, file=sys.stderr)
    if problems:
        sys.exit(1)
    print(
        "node shape fits the platform: "
        + ", ".join(checked)
        + "; each satisfies the profile's own capacity envelope (min "
        + f"{limits['min_vcpu_per_node']} vCPU / {limits['min_memory_gib_per_node']} GiB per node, "
        + f"largest pod {limits['largest_pod_vcpu']} vCPU, {limits['platform_vcpu']} vCPU / "
        + f"{limits['platform_memory_gib']} GiB with {HEADROOM_NODES} node held back)"
        + f", and leaves room for the loki chunk cache's {CHUNKS_CACHE_GIB:g} GiB"
    )


main()
