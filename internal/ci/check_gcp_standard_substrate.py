import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import tfconfig

SIZING = ("node_count", "node_machine_type", "node_disk_gb")


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    cluster_tf = root / "platform/cloud/gcp/cluster/main.tf"
    variables_tf = root / "platform/cloud/gcp/cluster/variables.tf"
    for path in (cluster_tf, variables_tf):
        if not path.is_file():
            sys.exit(f"FAIL: missing {path}")
    found = tfconfig.resources(cluster_tf, kinds=("resource",))
    cluster = next((r for r in found if r.type == "google_container_cluster" and r.name == "main"), None)
    if cluster is None:
        sys.exit('FAIL: the GCP cluster root declares no google_container_cluster "main"')
    problems = []
    if "enable_autopilot" in cluster.body:
        problems.append(
            "the cluster must not carry an enable_autopilot attribute at all: the google provider "
            "refuses it alongside remove_default_node_pool, and Sol states its substrate by not "
            "requesting Autopilot. Declaring the attribute -- even as false -- is a plan-time error "
            "(Attempt 15)"
        )
    if cluster.body.get("remove_default_node_pool") is not True:
        problems.append("the cluster's default node pool must be removed: Sol owns the pool it runs on")
    if tfconfig.variable_reference(cluster.body.get("location")) != "region":
        problems.append(
            "the cluster's control plane stays regional (location = var.region): every call site "
            "resolves it with --region, and making the control plane zonal is not what the substrate "
            "switch is about"
        )
    pools = [r for r in found if r.type == "google_container_node_pool"]
    if not pools:
        problems.append("a Standard cluster needs a node pool, and the driver must own it")
    for attribute in ("machine_type", "disk_size_gb"):
        values = [v for p in pools for v in tfconfig.attributes(p.body, attribute)]
        if not values or not all(tfconfig.variable_reference(v) for v in values):
            problems.append(
                f"the node pool's {attribute} must come from a driver variable, not a literal and not the target"
            )
    if not pools or not all(tfconfig.variable_reference(p.body.get("node_count")) for p in pools):
        problems.append("the node pool's count must come from a driver variable")
    declared = tfconfig.variables(variables_tf)
    for name in SIZING:
        if name not in declared:
            problems.append(f"{name} must be declared in the driver's variables")
        elif "default" not in declared[name]:
            problems.append(f"{name} must declare a default: these are driver-owned defaults, not required inputs")
    for contract in sorted(root.glob("cli/lib/**/sol_cli_config.ml*")):
        text = contract.read_text(encoding="utf-8")
        if any(name in text for name in SIZING):
            problems.append(
                f"node sizing must not appear in the target contract ({contract.relative_to(root)}): what "
                "should control sizing is a design decision, and not one to infer from a qualification run"
            )
    for problem in problems:
        print(f"FAIL: {problem}", file=sys.stderr)
    if problems:
        sys.exit(1)
    print("GCP substrate: the driver provisions GKE Standard (no Autopilot request, no knob), owns a")
    print("               node pool with driver-defaulted sizing, and keeps its control plane regional")


main()
