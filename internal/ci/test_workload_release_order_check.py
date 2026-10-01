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
        "(match deps.release_workloads () with",
        "(match deps.destroy_substrate () with",
    )
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_cloud_destroy.ml",
        "    match deps.destroy_substrate () with",
        "    match deps.remove_elevated_access () with",
    )
    expect_rejected("no-release", tmp, "no longer releases the workloads")

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_cloud_destroy.ml",
        """    (match deps.release_workloads () with
     | Ok () -> ()
     | Error message ->
       degrade""",
        """    (match deps.release_workloads () with
     | Ok () -> ()
     | Error message ->
       ignore""",
    )
    expect_rejected("release-failure-no-longer-degrades", tmp, "no longer degrades the teardown")

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
        "  @ names\n",
        "  @ [ \"deployment,cronjob,job\" ]\n",
    )
    expect_rejected("removal-goes-back-to-a-selector", tmp, "no longer names the workloads")

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_cloud_wiring.ml",
        "Sol_cli_config.destination_of_target target_cfg in\n",
        "Ok (Sol_cli_kube_destination.context_of_destination Sol_cli_kube_destination.local) in\n",
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
    print("  that drops the release, one that stops degrading, one that reads cluster-wide, one that")
    print("  selects a different label, one that stops waiting, one that reads the workload object")
    print("  instead of its pod template, one that forgets where a CronJob's template is, one that")
    print("  selects the objects instead of naming them, one that keeps the platform identity, one")
    print("  that drops the declared scope, one that inverts the layer graph, and one that reads the")
    print("  scope from the release store")


main()
