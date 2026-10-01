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


def main():
    result = run(ROOT)
    if result.returncode != 0:
        print("the guard rejects the real tree:")
        print(result.stdout)
        sys.exit(1)

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_cloud_destroy.ml",
        "      match deps.release_workloads () with",
        "      match deps.destroy_substrate () with",
    )
    expect_rejected("no-release", tmp, "no longer releases the workloads")

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_cloud_destroy.ml",
        """    match released with
    | Error message -> fail ~cleanup (Workload_release_unestablished message)""",
        """    match released with
    | Error message -> ignore message""",
    )
    expect_rejected(
        "unestablished-release-no-longer-stops",
        tmp,
        "no longer stops the destroy before the substrate",
    )

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_cloud_destroy.ml",
        "| Workloads_unestablished message when deps.accept_unreleased ->",
        "| Workloads_unestablished message when false ->",
    )
    expect_rejected(
        "the-explicit-override-is-dropped",
        tmp,
        "no longer consulted",
    )

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_cloud_wiring.ml",
        "Sol_cli_kubectl.cluster_unreachable e",
        "false",
        count=2,
    )
    expect_rejected(
        "an-unreachable-cluster-is-no-longer-distinguished",
        tmp,
        "no longer tells an unreachable cluster apart",
    )

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_workload_scope.ml",
        '"-n"; namespace',
        '"--all-namespaces"; namespace',
        count=2,
    )
    expect_rejected("read-is-cluster-wide", tmp, "cluster-wide again")

    tmp = scratch()
    mutate(tmp, "cli/lib/cloud/sol_cli_workload_scope.ml", '"workspace=" ^ workspace', '"app=" ^ workspace')
    expect_rejected("read-selects-a-different-label", tmp, "ownership label Sol renders")

    tmp = scratch()
    mutate(tmp, "cli/lib/cloud/sol_cli_workload_scope.ml", '"--for=delete"', '"--for=ready"')
    expect_rejected("release-stops-waiting-for-the-pods", tmp, "no longer waits")

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_workload_scope.ml",
        '[ "spec"; "template"; "metadata"; "labels" ]',
        '[ "metadata"; "labels" ]',
    )
    expect_rejected(
        "selection-reads-the-object-rather-than-its-pod-template",
        tmp,
        "no longer selects workloads by the ownership labels",
    )

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_workload_scope.ml",
        '[ "spec"; "jobTemplate" ]',
        '[ "metadata" ]',
    )
    expect_rejected(
        "cronjob-template-forgotten",
        tmp,
        "no longer knows where a CronJob's pod template is",
    )

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_workload_scope.ml",
        "let kinds = [ Deployment; CronJob; Job; Rollout ]",
        "let kinds = [ Deployment; CronJob; Job ]",
    )
    expect_rejected("the-rollout-kind-is-dropped", tmp, "no longer covers Rollout")

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_workload_scope.ml",
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
        "cli/lib/cloud/sol_cli_cloud_wiring.ml",
        "Sol_cli_workload_scope.optional_kind kind",
        "true",
    )
    expect_rejected(
        "an-unserved-kind-is-no-longer-absence",
        tmp,
        "no longer read as absence",
    )

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_workload_scope.ml",
        "  @ names\n",
        "  @ [ \"deployment,cronjob,job\" ]\n",
    )
    expect_rejected("removal-goes-back-to-a-selector", tmp, "no longer names the workloads")

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_cloud_wiring.ml",
        "match Sol_cli_config.destination_of_target target_cfg with",
        "match Ok Sol_cli_kube_destination.local with",
    )
    expect_rejected("release-runs-as-the-platform-identity", tmp, "no longer runs as the target's deploy identity")

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
        "cli/lib/cloud/dune",
        "(libraries sol_cli_base sol_cli_kube sol_cli_workspace unix yojson)",
        "(libraries sol_cli_base sol_cli_kube sol_cli_workspace sol_cli_deploy unix yojson)",
    )
    expect_rejected("cloud-depends-on-deploy", tmp, "inverting the library graph")

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_cloud_destroy.ml",
        "    deps.report \"\\nReleasing the application workloads...\";",
        "    deps.report \"\\nReleasing the application workloads...\";\n    ignore Sol_cli_release_store.list;",
    )
    expect_rejected("scope-read-from-the-release-store", tmp, "reads release-store state")

    print("test_workload_release_order_check: the guard accepts the real tree and rejects a destroy")
    print("  that drops the release, one that no longer stops before the substrate when the release")
    print("  is unestablished, one that drops the explicit override, one that stops distinguishing an")
    print("  unreachable cluster, one that reads cluster-wide, one that selects a different label,")
    print("  one that stops waiting, one that reads the workload object instead of its pod template,")
    print("  one that forgets where a CronJob's template is, one that drops the progressive-delivery")
    print("  Rollout from the kinds it covers, one that reads the kinds in a single listing again, one")
    print("  that reads an unserved kind as a failed release, one that selects the objects instead of")
    print("  naming them, one that keeps the platform identity, one that drops the declared scope, one")
    print("  that inverts the layer graph, and one that reads the scope from the release store")


main()
