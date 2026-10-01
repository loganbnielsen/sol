"""The destroy releases Sol-owned workloads before it destroys the substrate.

Destroying a target whose application holds pooled sessions to the managed database fails part-way:
the provider refuses to drop the database while those sessions are open (FND-0077). The lifecycle
encodes the reverse of the deployment order, and the scope of that work has a deliberate boundary:

    declared target configuration says WHERE to look
    observed cluster state says WHAT is there and who owns it
    -> release those workloads, waiting for their pods to go
    -> destroy the substrate
    -> independently verify absence

Four failures shaped this. Listing pods cluster-wide ran as the provisioner identity, which by
design has no cluster-wide pod authority, so the release could never run. Reading the release store
was the other obvious source, and it would invert the library graph (`base <- kube <- workspace <-
cloud <- deploy`) besides depending on a record that can be stale or absent. Selecting the
workload objects by the ownership label matched nothing, because Sol renders that label on each
workload's pod template rather than on the object's own metadata, so the objects were never removed
and their pods stayed up holding the sessions. And the listing named only some of the kinds Sol
deploys: a service that opts into progressive delivery renders an Argo `Rollout` (FEAT-011), whose
pods carry the same ownership label on the same pod template, and a destroy that never read the kind
left that workload's sessions open — FND-0077's failure for a shape the read did not reach.

Naming `rollout` beside the built-in kinds in one listing is not the fix. It is a custom resource: a
cluster where the controller that serves it is not installed fails that whole read, so the release
would lose the kinds that are there. The read therefore names one kind at a time, and an unserved
kind is absence only where the kind is one a controller installs — never for the built-in kinds the
platform itself installs, where a failed read must stay a failed read rather than an empty scope.

This guard holds the parts that are cheap to check and easy to undo by accident: the read is scoped
to a declared namespace rather than the cluster, it runs as the deploy identity rather than the
platform's, it names every workload kind Sol deploys one at a time and reads an unserved
controller-installed kind as absence, it selects the ownership labels Sol renders on the pod
template, it removes the objects it discovered by name, it waits for the pods, it precedes the
substrate destroy, and a release failure degrades rather than blocking.
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
wiring_ml = read("cli/lib/cloud/sol_cli_cloud_wiring.ml", "the workload release cannot be checked")
cloud_dune = read("cli/lib/cloud/dune", "the layer boundaries cannot be checked")
cli_tf = read("cli/bin/cmd_cloud_tf.ml", "the declared scope cannot be checked")

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

if '"get"' not in scope_ml or '"-n"' not in scope_ml:
    fail("the workload read is no longer a namespaced listing, so its scope is not the")
    fail("  declared namespace")
if '"--all-namespaces"' in scope_ml:
    fail("a read is cluster-wide again, which the platform identity is not allowed to do and")
    fail("  which is why the release could never run")
if '"workspace=" ^ workspace' not in scope_ml:
    fail("the workload read no longer selects the ownership label Sol renders for a workspace,")
    fail("  so what it finds is no longer tied to what Sol deployed")
if '"--for=delete"' not in scope_ml or '"--wait=true"' not in scope_ml or '"pod"' not in scope_ml:
    fail("the release no longer waits for the pods, so they may still hold their database")
    fail("  sessions when the substrate destroy asks the provider to drop the database")
covered = re.search(r"let kinds = \[([^\]]*)\]", scope_ml)
if covered is None:
    fail("the workload kinds the release covers are no longer declared in one list, so the set of")
    fail("  objects whose pods can hold the database sessions cannot be checked")
declared_kinds = {kind.strip() for kind in covered.group(1).split(";")}
for kind in ("Deployment", "CronJob", "Job", "Rollout"):
    if kind not in declared_kinds:
        fail(f"the release no longer covers {kind}, so a service deployed in that shape keeps its")
        fail("  database sessions through the substrate destroy, which is how an Argo Rollout was")
        fail("  left running and the managed database refused the drop")
listing = re.search(r"let list_args [^=]*=\s*\[([^\]]*)\]", scope_ml)
if listing is None or "resource_of_kind kind" not in listing.group(1):
    fail("the release no longer reads one workload kind at a time, so where the controller-installed")
    fail("  Rollouts custom resource is not served the whole read fails and the workloads that are")
    fail("  there go unreleased")
if '"spec"; "template"; "metadata"; "labels"' not in scope_ml:
    fail("the release no longer selects workloads by the ownership labels on their pod template;")
    fail("  the objects themselves carry no labels, so a selector on them matches nothing and the")
    fail("  pods stay up holding their database sessions")
if '"spec"; "jobTemplate"' not in scope_ml:
    fail("the release no longer knows where a CronJob's pod template is, so the pods of a scheduled")
    fail("  function keep their database sessions through the substrate destroy")
if "@ names" not in scope_ml:
    fail("the removal no longer names the workloads it found, so it cannot delete objects that carry")
    fail("  no labels of their own")

release_wiring = wiring_ml[wiring_ml.find("let release_workloads_result") : wiring_ml.find("let deps : Sol_cli_cloud_destroy.deps =")]
if "Sol_cli_config.destination_of_target target_cfg" not in release_wiring:
    fail("the release no longer runs as the target's deploy identity, which is the authority the")
    fail("  deploy path uses and the only one that may read these namespaces")
if "with_cluster_access_result" in release_wiring:
    fail("the release runs as the platform's cluster-access identity again, which cannot read")
    fail("  application namespaces")
if "workload_namespaces" not in wiring_ml:
    fail("the release no longer takes the declared namespaces as its scope")
if "Sol_cli_workload_scope.kinds" not in release_wiring:
    fail("the release no longer walks the kinds Sol deploys, so a kind it stopped naming would go")
    fail("  unreleased with nothing said about it")
if "optional_kind" not in release_wiring or "No_resource_type" not in release_wiring:
    fail("an unserved workload kind is no longer read as absence: where the controller-installed")
    fail("  Rollouts custom resource is not served the release fails instead of releasing the kinds")
    fail("  that are there, and where a built-in kind cannot be read it must still fail rather than")
    fail("  read as an empty scope")

if "declared_workload_namespaces" not in cli_tf:
    fail("the destroy command no longer supplies the declared namespace scope")
if "Sol_cli_workspace_model.services" not in cli_tf or "namespace_name" not in cli_tf:
    fail("the declared scope is no longer derived from the workspace's declared services")

libraries = re.search(r"\(libraries([^)]*)\)", cloud_dune)
if libraries is None:
    fail("cli/lib/cloud/dune no longer declares its libraries")
declared = set(libraries.group(1).split())
for required in ("sol_cli_base", "sol_cli_kube", "sol_cli_workspace"):
    if required not in declared:
        fail(f"the cloud layer no longer depends on {required}")
if "sol_cli_deploy" in declared:
    fail("the cloud layer now depends on sol_cli_deploy, inverting the library graph; the declared")
    fail("  scope comes from the workspace layer, and the deploy layer consumes the cloud layer")
if "Sol_cli_release_store" in destroy_ml or "Sol_cli_release_store" in scope_ml:
    fail("the destroy reads release-store state to decide its workload scope, which makes teardown")
    fail("  depend on a record that can be stale or absent; discovery comes from the cluster")

print("check_workload_release_order: the destroy takes its scope from the declared configuration,")
print("                            reads ownership from the cluster as the deploy identity, names")
print("                            every workload kind Sol deploys one at a time -- reading an")
print("                            unserved controller-installed kind as absence -- waits for the")
print("                            pods, releases before destroying the substrate, and degrades")
print("                            rather than blocks when the release cannot run")
