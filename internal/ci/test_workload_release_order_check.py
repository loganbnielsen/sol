import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(".").resolve()
GUARD = "internal/ci/check_workload_release_order.py"

COPIED = [
    "cli/lib/cloud/sol_cli_cloud_destroy.ml",
    "cli/lib/cloud/sol_cli_cloud_destroy.mli",
    "cli/lib/cloud/sol_cli_workload_scope.ml",
    "cli/lib/cloud/sol_cli_cloud_wiring.ml",
    "cli/lib/cloud/dune",
    "cli/bin/cmd_cloud_tf.ml",
]


def scratch():
    tmp = pathlib.Path(tempfile.mkdtemp())
    for relative in COPIED:
        target = tmp / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / relative, target)
    return tmp


def run(tmp):
    return subprocess.run(
        [sys.executable, str(ROOT / GUARD), str(tmp)],
        capture_output=True,
        text=True,
    )


def mutate(tmp, relative, old, new, count=1):
    path = tmp / relative
    text = path.read_text()
    if text.count(old) != count:
        print(f"mutation anchor not found in {relative}: {old!r} ({text.count(old)} times)")
        sys.exit(1)
    path.write_text(text.replace(old, new, count))


def expect_rejected(name, tmp, needle):
    result = run(tmp)
    if result.returncode == 0:
        print(f"  ACCEPTED: {name} -- the guard did not reject it")
        sys.exit(1)
    if needle not in result.stdout:
        print(f"  WRONG REASON: {name} -- {result.stdout.strip()}")
        sys.exit(1)
    print(f"  rejected: {name}")


DESTROY = "cli/lib/cloud/sol_cli_cloud_destroy.ml"
SCOPE = "cli/lib/cloud/sol_cli_workload_scope.ml"
WIRING = "cli/lib/cloud/sol_cli_cloud_wiring.ml"


def main():
    result = run(ROOT)
    if result.returncode != 0:
        print("the guard rejects the real tree:")
        print(result.stdout)
        sys.exit(1)

    tmp = scratch()
    mutate(tmp, DESTROY, "release_decision (deps.release_workloads ())", "Ok ()")
    expect_rejected("no-release", tmp, "no longer releases the workloads")

    tmp = scratch()
    mutate(tmp, DESTROY, "| Error stopped -> stopped", "| Error _ -> Ok ()")
    expect_rejected(
        "release-stop-discarded",
        tmp,
        "no longer returns the unestablished release",
    )

    tmp = scratch()
    mutate(tmp, DESTROY, "if deps.accept_unreleased", "if true")
    expect_rejected(
        "override-no-longer-gates-the-stop",
        tmp,
        "no longer gates the stop",
    )

    tmp = scratch()
    mutate(
        tmp,
        DESTROY,
        "(Release_unestablished (Sol_cli_workload_scope.failure_to_string failure))",
        "(Verification_failed (Sol_cli_workload_scope.failure_to_string failure))",
    )
    expect_rejected(
        "the-release-no-longer-raises-the-stop",
        tmp,
        "no longer fails the destroy",
    )

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_cloud_destroy.mli",
        "| Release_unestablished of string",
        "| Verification_failed of string",
    )
    expect_rejected(
        "the-stop-is-not-its-own-failure",
        tmp,
        "no longer names an unestablished workload release as its own failure",
    )

    tmp = scratch()
    mutate(tmp, DESTROY, "if !substrate = Substrate_absent", "if false")
    expect_rejected(
        "no-substrate-carve-out",
        tmp,
        "no longer skips the release",
    )

    tmp = scratch()
    mutate(tmp, DESTROY, "let release_decision release =", "let release_decision _ =")
    expect_rejected(
        "the-release-outcome-is-not-classified",
        tmp,
        "longer classifies its outcome",
    )

    tmp = scratch()
    mutate(
        tmp,
        DESTROY,
        'deps.report "\\nReleasing the application workloads...";',
        'deps.report "\\nReleasing the application workloads...";\n               ignore Sol_cli_release_store.list;',
    )
    expect_rejected("scope-read-from-the-release-store", tmp, "reads release-store state")

    tmp = scratch()
    mutate(tmp, SCOPE, '"-n"; namespace', '"--all-namespaces"; namespace')
    expect_rejected("read-is-cluster-wide", tmp, "cluster-wide again")

    tmp = scratch()
    mutate(tmp, SCOPE, '"workspace=" ^ workspace', '"app=" ^ workspace')
    expect_rejected("read-selects-a-different-label", tmp, "ownership label Sol renders")

    tmp = scratch()
    mutate(tmp, SCOPE, '"--for=delete"', '"--for=ready"')
    expect_rejected("release-stops-waiting-for-the-pods", tmp, "no longer waits")

    tmp = scratch()
    mutate(tmp, SCOPE, '"--ignore-not-found"', '"--wait=false"')
    expect_rejected(
        "removal-stops-tolerating-an-absent-object",
        tmp,
        "no longer tolerates a workload that is already gone",
    )

    tmp = scratch()
    mutate(
        tmp,
        SCOPE,
        '[ "spec"; "template"; "metadata"; "labels" ]',
        '[ "metadata"; "labels" ]',
    )
    expect_rejected(
        "selection-reads-the-object-rather-than-its-pod-template",
        tmp,
        "no longer selects workloads by the ownership labels",
    )

    tmp = scratch()
    mutate(tmp, SCOPE, '[ "spec"; "jobTemplate" ]', '[ "metadata" ]')
    expect_rejected(
        "cronjob-template-forgotten",
        tmp,
        "no longer knows where a CronJob's pod template is",
    )

    tmp = scratch()
    mutate(
        tmp,
        SCOPE,
        "let kinds = [ Deployment; CronJob; Job; Rollout ]",
        "let kinds = [ Deployment; CronJob; Job ]",
    )
    expect_rejected("the-rollout-kind-is-dropped", tmp, "no longer covers Rollout")

    tmp = scratch()
    mutate(
        tmp,
        SCOPE,
        '[ "get"; resource_of_kind kind; "-n"; namespace; "--output"; "json" ]',
        '[ "get"; "deployment,cronjob,job,rollout"; "-n"; namespace; "--output"; "json" ]',
    )
    expect_rejected(
        "the-kinds-are-read-in-one-listing",
        tmp,
        "no longer reads one workload kind at a time",
    )

    tmp = scratch()
    mutate(
        tmp,
        SCOPE,
        "Sol_cli_kubectl.No_resource_type when optional_kind kind",
        "Sol_cli_kubectl.No_resource_type when true",
    )
    expect_rejected(
        "an-unserved-kind-is-no-longer-absence",
        tmp,
        "no longer read as absence",
    )

    tmp = scratch()
    mutate(tmp, SCOPE, "Sol_cli_kubectl.Not_found", "Sol_cli_kubectl.Conflict")
    expect_rejected(
        "namespace-absence-is-no-longer-absence",
        tmp,
        "no longer absence of that scope",
    )

    tmp = scratch()
    mutate(tmp, SCOPE, "Unreachable when not contacted", "Unreachable when not false")
    expect_rejected(
        "an-unreachable-cluster-is-unbounded",
        tmp,
        "no longer bounded to before the",
    )

    tmp = scratch()
    mutate(tmp, SCOPE, "  @ names\n", "  @ [ \"deployment,cronjob,job\" ]\n")
    expect_rejected("removal-goes-back-to-a-selector", tmp, "no longer names the workloads")

    tmp = scratch()
    mutate(
        tmp,
        WIRING,
        "match Sol_cli_config.destination_of_target target_cfg with",
        "match Ok (Sol_cli_kube_destination.context_of_destination Sol_cli_kube_destination.local) with",
    )
    expect_rejected(
        "release-runs-as-the-platform-identity",
        tmp,
        "no longer runs as the target's deploy identity",
    )

    tmp = scratch()
    mutate(tmp, WIRING, "read_workloads ~run", "read_nothing")
    expect_rejected(
        "the-release-no-longer-runs-discovery",
        tmp,
        "no longer runs the workload discovery",
    )

    tmp = scratch()
    mutate(tmp, WIRING, "~accept_unreleased", "~accept_unreleased_removed")
    expect_rejected(
        "the-override-is-not-passed-through",
        tmp,
        "no longer carries the operator's override",
    )

    tmp = scratch()
    mutate(
        tmp,
        "cli/bin/cmd_cloud_tf.ml",
        "declared_workload_namespaces",
        "undeclared_workload_scope",
        count=2,
    )
    expect_rejected("declared-scope-dropped", tmp, "no longer supplies the declared namespace scope")

    tmp = scratch()
    mutate(
        tmp,
        "cli/bin/cmd_cloud_tf.ml",
        "[ Sol_cli_cloud_destroy.accept_unreleased_flag ]",
        "[ Sol_cli_cloud_destroy.accept_unreleased_flag; \"--force\" ]",
    )
    expect_rejected("the-override-becomes-a-generic-force", tmp, "a blanket --force was added")

    tmp = scratch()
    mutate(
        tmp,
        "cli/bin/cmd_cloud_tf.ml",
        "Sol_cli_cloud_destroy.accept_unreleased_flag",
        '"accept-it-anyway"',
    )
    expect_rejected(
        "the-override-is-declared-under-another-name",
        tmp,
        "no longer declares the override under the one name",
    )

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/dune",
        "(libraries sol_cli_base sol_cli_kube sol_cli_workspace unix yojson)",
        "(libraries sol_cli_base sol_cli_kube sol_cli_workspace sol_cli_deploy unix yojson)",
    )
    expect_rejected("cloud-depends-on-deploy", tmp, "inverting the library graph")

    print("test_workload_release_order_check: the guard accepts the real tree and rejects a destroy")
    print("  that drops the release, one that discards the stop, one whose override no longer gates")
    print("  it, one that reports the stop as another failure, one with no absent-substrate")
    print("  carve-out, one that stops classifying the outcome, one that reads the scope from the")
    print("  release store, ones that read cluster-wide or under a different label, one that stops")
    print("  waiting, one that stops tolerating an absent object, ones that read the workload object")
    print("  instead of its pod template or forget a CronJob's template, ones that drop the")
    print("  progressive-delivery Rollout or read the kinds in one listing, ones that stop reading")
    print("  an unserved kind or an absent namespace as absence, one that leaves the reachable-cluster")
    print("  carve-out unbounded, one that selects the objects instead of naming them, one that keeps")
    print("  the platform identity, one that stops running discovery, one that drops the override on")
    print("  the way to the destroy, one that drops the declared scope, ones that widen the override")
    print("  into a generic force or rename it, and one that inverts the layer graph")


main()
