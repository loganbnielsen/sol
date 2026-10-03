"""The destroy releases Sol-owned workloads before it destroys anything, and stops if it cannot.

Destroying a target whose application holds pooled sessions to the managed database fails part-way:
the provider refuses to drop the database while those sessions are open (FND-0077). The lifecycle
encodes the reverse of the deployment order, and the scope of that work has a deliberate boundary:

    declared target configuration says WHERE to look
    observed cluster state says WHAT is there and who owns it
    -> release those workloads, waiting for their pods to go
    -> destroy the platform, the substrate, and the temporary authority
    -> independently verify absence

Four failures shaped the discovery. Listing pods cluster-wide ran as the provisioner identity, which
by design has no cluster-wide pod authority, so the release could never run. Reading the release store
was the other obvious source, and it would invert the library graph (`base <- kube <- workspace <-
cloud <- deploy`) besides depending on a record that can be stale or absent. Selecting the workload
objects by the ownership label matched nothing, because Sol renders that label on each workload's pod
template rather than on the object's own metadata, so the objects were never removed and their pods
stayed up holding the sessions. And the listing named only some of the kinds Sol deploys: a service
that opts into progressive delivery renders an Argo `Rollout` (FEAT-011), whose pods carry the same
ownership label on the same pod template, and a destroy that never read the kind left that workload's
sessions open — FND-0077's failure for a shape the read did not reach.

Naming `rollout` beside the built-in kinds in one listing is not the fix. It is a custom resource: a
cluster where the controller that serves it is not installed fails that whole read, so the release
would lose the kinds that are there. The read therefore names one kind at a time, and an unserved
kind is absence only where the kind is one a controller installs — never for the built-in kinds the
platform itself installs, where a failed read must stay a failed read rather than an empty scope.

DEC-059 then replaced the rule the first correction carried. A release that failed used to degrade
and let the substrate destroy run anyway, on the reasoning that a teardown must not depend on a step
that can fail (ADR 0003 invariant 6). That reasoning holds for a probe whose only job is to classify
the target; it does not hold for a removal that exists to keep the provider from dropping durable
application state while clients hold it. The live record shows the cost: the release could not remove
the workloads, the run warned, `terraform destroy` ran anyway, the database refused the drop, and the
target was left half destroyed — not absent, not usable, and needing a second invocation to reason
about. A destroy that cannot establish the workloads are released now stops before it destroys
anything. The valid core of the old rule is preserved as a carve-out and an override:

    the substrate is absent                  -> no cluster, no workload: the release is not attempted
    the substrate is provably absent         -> the same, when the state still represents other cloud
                                                objects but the provider no longer has the cluster
                                                (INFRA-094: nothing inside it can be running)
    the cluster cannot be reached at all     -> proceed, recorded as a degradation (never stranded)
    the cluster answered and the read failed -> stop: absence is not established (DEC-038)
    a declared namespace does not exist      -> absence of that scope, not a failed release
    an unserved controller-installed kind    -> absence of that kind (INFRA-097)
    nothing found / removed / pods gone      -> released
    anything else                            -> stop, unless --accept-unreleased was given

The override is named for what it accepts, never the default, and the run records that the absence
check — not the release — decided the outcome. Nothing here may be a generic `--force`.

This guard holds the parts that are cheap to check and easy to undo by accident: the read is scoped
to a declared namespace rather than the cluster, it runs as the deploy identity rather than the
platform's, it names every workload kind Sol deploys one at a time and reads an unserved
controller-installed kind as absence, it selects the ownership labels Sol renders on the pod
template, it removes the objects it discovered by name, it waits for the pods, it runs before
anything is destroyed, it stops when it cannot establish the release, and only the explicit override
lets it proceed.
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

if "; release_workloads : unit -> Sol_cli_workload_scope.release" not in destroy_mli:
    fail("the destroy interface no longer declares the workload release step, or no longer takes")
    fail("  its classified outcome: a bare result cannot say whether absence was established")
if "; accept_unreleased : bool" not in destroy_mli:
    fail("the destroy no longer takes the operator's override, so an unestablished release has no")
    fail("  documented way forward that keeps the operator in control")
if "Release_unestablished of string" not in destroy_mli:
    fail("the destroy no longer names an unestablished workload release as its own failure, which")
    fail("  is a different failure from a substrate destroy or a platform teardown that failed")

release_at = destroy_ml.find("release_decision (deps.release_workloads ())")
substrate_at = destroy_ml.find("deps.destroy_substrate ()")
if release_at < 0:
    fail("the destroy no longer releases the workloads, so a database with open sessions it")
    fail("  cannot see is dropped, which is the whole of FND-0077")
if substrate_at < 0:
    fail("the destroy no longer destroys the substrate, so this guard is checking nothing")

release_block_start = destroy_ml.find("let release =")
execute_end = destroy_ml.find("let guard_preparation_policy")
if release_block_start < 0 or execute_end < release_block_start:
    fail("the workload release is no longer a decision the destroy takes before it destroys")
release_block = destroy_ml[release_block_start:execute_end]
if release_block.find("release_decision (deps.release_workloads ())") < 0:
    fail("the release no longer runs before anything is destroyed, so its stop cannot gate one")
if release_block.find("| Ok () ->") < release_block.find("release_decision"):
    fail("the substrate destroy no longer sits behind the release's released branch")
if "substrate = Substrate_absent" not in release_block or "then Ok ()" not in release_block:
    fail("a target whose substrate is already absent no longer skips the release, so an")
    fail("  idempotent re-destroy would warn about a cluster it never needed (DEC-059)")
if "| Error stopped -> stopped" not in release_block:
    fail("the destroy no longer returns the unestablished release: the stop is discarded and the")
    fail("  run proceeds into destruction it cannot justify (DEC-059)")

definition = destroy_ml.find("let destroy_and_verify")
if definition < 0:
    fail("the destroy no longer verifies its own teardown, so this guard is checking nothing")
verification_calls = [
    found.start()
    for found in re.finditer(
        r"(?<!let )destroy_and_verify ~cloud_exists ~cleanup ~preparation", destroy_ml
    )
]
if not verification_calls:
    fail("nothing destroys the substrate any more, so this guard is checking nothing")
for at in verification_calls:
    if not release_block_start <= at <= execute_end:
        fail("the substrate is destroyed on a path that does not pass the workload release's")
        fail("  released branch, so an unestablished release can be proceeded past (DEC-059)")

decision_start = destroy_ml.find("let release_decision release =")
decision_end = destroy_ml.find("let destroy_and_verify ")
if decision_start < 0 or decision_end < 0:
    fail("the workload release no longer classifies its outcome before the destruction, so the")
    fail("  stop this guard exists for cannot be checked")
decision = destroy_ml[decision_start:decision_end]
if "deps.accept_unreleased" not in decision:
    fail("the operator's override no longer gates the stop, so either the destroy always stops or")
    fail("  it always proceeds: the classification decides, and the override accepts it explicitly")
if "(Release_unestablished" not in decision:
    fail("an unestablished release no longer fails the destroy, which is the degrade-and-continue")
    fail("  rule DEC-059 replaced after it left a target half destroyed")
if "degrade" not in decision:
    fail("an overridden release is no longer recorded, so a destroy that proceeds with the")
    fail("  workloads unreleased would say nothing about it")
if "the workloads this target deployed could not be released" in destroy_ml:
    fail("the destroy reports an unreleased workload set as a degradation of a teardown it then")
    fail("  continues, which DEC-059 replaced: the release is a destruction-time precondition")

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
if '"--ignore-not-found"' not in scope_ml:
    fail("the removal no longer tolerates a workload that is already gone: an object that vanishes")
    fail("  between the read and the removal would stop a teardown that has nothing left to do")
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
if "No_resource_type when optional_kind kind" not in scope_ml:
    fail("an unserved workload kind is no longer read as absence: where the controller-installed")
    fail("  Rollouts custom resource is not served, the release would fail instead of releasing the")
    fail("  kinds that are there")
if "Sol_cli_kubectl.Not_found" not in scope_ml:
    fail("a declared namespace that does not exist is no longer absence of that scope, so a target")
    fail("  whose apply never created its namespace could not be destroyed")
if "Unreachable when not contacted" not in scope_ml:
    fail("the carve-out for a cluster that cannot be reached is no longer bounded to before the")
    fail("  first answer: a cluster that answered and then went away must be an unestablished")
    fail("  release, which is the fail-closed direction (DEC-038)")
if "No_cluster" not in scope_ml or "Read_unestablished" not in scope_ml:
    fail("the read no longer separates 'there is no cluster to release from' from 'the cluster")
    fail("  answered and Sol could not establish absence', which DEC-059's classification needs")

for outcome in ("Workloads_released", "Workloads_not_releasable", "Workloads_unestablished"):
    if outcome not in destroy_ml:
        fail(f"the destroy no longer acts on {outcome}, so a release outcome has no defined")
        fail("  behaviour and the classification cannot be read off the code")

release_wiring = wiring_ml[wiring_ml.find("let release_workloads_result") : wiring_ml.find("let deps : Sol_cli_cloud_destroy.deps =")]
if "Sol_cli_config.destination_of_target target_cfg" not in release_wiring:
    fail("the release no longer runs as the target's deploy identity, which is the authority the")
    fail("  deploy path uses and the only one that may read these namespaces")
if "with_cluster_access_result" in release_wiring:
    fail("the release runs as the platform's cluster-access identity again, which cannot read")
    fail("  application namespaces")
if "workload_namespaces" not in wiring_ml:
    fail("the release no longer takes the declared namespaces as its scope")
if "[] kinds" not in scope_ml:
    fail("the release no longer walks the kinds Sol deploys, so a kind it stopped naming would go")
    fail("  unreleased with nothing said about it")
if "read_workloads ~run ~namespaces:workload_namespaces ~workspace" not in release_wiring:
    fail("the release no longer runs the workload discovery against the declared namespaces, so")
    fail("  nothing this target deployed is released before the substrate is destroyed")
if "No_cluster" not in release_wiring or "Read_unestablished" not in release_wiring:
    fail("the wiring no longer turns the read's outcome into the destroy's classification, so the")
    fail("  carve-out and the stop cannot both be honoured")
if not re.search(r"~accept_unreleased\b", wiring_ml) or "; accept_unreleased" not in wiring_ml:
    fail("the wiring no longer carries the operator's override through to the destroy, so the")
    fail("  classification could never be accepted explicitly")

if "declared_workload_namespaces" not in cli_tf:
    fail("the destroy command no longer supplies the declared namespace scope")
if "Sol_cli_workspace_model.services" not in cli_tf or "namespace_name" not in cli_tf:
    fail("the declared scope is no longer derived from the workspace's declared services")
if "Sol_cli_cloud_destroy.accept_unreleased_flag" not in cli_tf:
    fail("the destroy command no longer declares the override under the one name the message")
    fail("  that offers it uses")
if '"--force"' in cli_tf:
    fail("a blanket --force was added: the override must name the precondition it accepts, which")
    fail("  DEC-059 forbids reading as a general bypass")

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
print("                            pods, runs before anything is destroyed, stops when it cannot")
print("                            establish the release, and proceeds past that only for the")
print("                            explicitly given override")
