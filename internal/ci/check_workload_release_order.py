"""The destroy releases Sol-owned workloads before it destroys the substrate.

Destroying a target whose application holds pooled sessions to the managed database fails part-way:
the provider refuses to drop the database while those sessions are open (FND-0077). The lifecycle
therefore has to encode the reverse of the deployment order, and it has to discover its scope from
cluster reality:

    discover the Sol-owned workload scope from the cluster
    -> remove the workloads and wait for their pods to go
    -> destroy the substrate
    -> independently verify absence

This guard holds the pieces of that contract that are cheap to check and easy to undo by accident:
the release precedes the substrate destroy, a release failure degrades rather than blocks, the
discovery selects on the ownership label Sol actually renders, and the scope is read from the
cluster rather than from release-store state, which would invert the library dependency graph
(`base <- kube <- workspace <- cloud <- deploy`).
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")


def read(path, missing):
    candidate = ROOT / path
    if not candidate.is_file():
        print(f"FAIL: {path} is missing, so {missing}")
        sys.exit(1)
    return candidate.read_text()


def fail(*lines):
    for line in lines:
        print(f"FAIL: {line}")
    sys.exit(1)


destroy_ml = read("cli/lib/cloud/sol_cli_cloud_destroy.ml", "the release ordering cannot be checked")
destroy_mli = read("cli/lib/cloud/sol_cli_cloud_destroy.mli", "the destroy interface cannot be checked")
scope_ml = read("cli/lib/cloud/sol_cli_workload_scope.ml", "the workload discovery cannot be checked")
cloud_dune = read("cli/lib/cloud/dune", "the layer boundaries cannot be checked")

if "; release_workloads : unit -> (unit, string) result" not in destroy_mli:
    fail("the destroy interface no longer declares the workload release step")

release_at = destroy_ml.find("deps.release_workloads ()")
substrate_at = destroy_ml.find("deps.destroy_substrate ()")
if release_at < 0:
    fail("the destroy no longer releases the workloads, so a database with open sessions it")
if substrate_at < 0:
    fail("the destroy no longer destroys the substrate, so this guard is checking nothing")
if release_at > substrate_at:
    fail("the destroy destroys the substrate before it releases the workloads, which is the")
    fail("  ordering that made a supported destroy fail on the managed database")

release_block_start = destroy_ml.find("(match deps.release_workloads () with")
release_block_end = destroy_ml.find("deps.destroy_substrate ()")
if release_block_start < 0:
    fail("the workload release is no longer a matched result, so its failure cannot be classified")
release_block = destroy_ml[release_block_start:release_block_end]
if "degrade" not in release_block:
    fail("a workload-release failure no longer degrades the teardown: a release that cannot run")
    fail("  must be reported and teardown must continue, not block it")
if re.search(r"\bfail\b\s*\(", release_block):
    fail("a workload-release failure now fails the destroy outright instead of degrading it")

if "\"workspace=\" ^ workspace" not in scope_ml:
    fail("the workload discovery no longer selects on the ownership label Sol renders for a")
    fail("  workspace, so what it finds is no longer tied to what Sol deployed")
if '"pods"' not in scope_ml or '"--all-namespaces"' not in scope_ml:
    fail("the workload discovery no longer reads pods across every namespace, so a namespace")
if "--wait=true" not in scope_ml:
    fail("the workload removal no longer waits, so the pods may still hold their database")
    fail("  sessions when the substrate destroy asks the provider to drop the database")

libraries = re.search(r"\(libraries([^)]*)\)", cloud_dune)
if libraries is None:
    fail("cli/lib/cloud/dune no longer declares its libraries")
declared = set(libraries.group(1).split())
for required in ("sol_cli_base", "sol_cli_kube", "sol_cli_workspace"):
    if required not in declared:
        fail(f"the cloud layer no longer depends on {required}")
if "sol_cli_deploy" in declared:
    fail("the cloud layer now depends on sol_cli_deploy, inverting the library graph; the workload")
    fail("  scope must come from the cluster, not from release-store state in the deploy layer")
if "Sol_cli_release_store" in destroy_ml or "Sol_cli_release_store" in scope_ml:
    fail("the destroy reads release-store state to decide its workload scope, which makes teardown")
    fail("  depend on a record that can be stale or absent; discovery comes from the cluster")

print("check_workload_release_order: the destroy discovers its workload scope from the cluster,")
print("                            releases it before destroying the substrate, degrades rather")
print("                            than blocks on a release failure, and keeps the layer graph")
