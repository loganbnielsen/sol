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
    "cli/lib/cloud/dune",
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
    mutate(tmp, "cli/lib/cloud/sol_cli_workload_scope.ml", '"workspace=" ^ workspace', '"app=" ^ workspace')
    expect_rejected("discovery-selects-a-different-label", tmp, "ownership label Sol renders")

    tmp = scratch()
    mutate(tmp, "cli/lib/cloud/sol_cli_workload_scope.ml", '"--wait=true"', '"--wait=false"')
    expect_rejected("removal-stops-waiting", tmp, "no longer waits")

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
    print("  that drops the release, one that stops degrading, one that selects a different label,")
    print("  one that stops waiting, one that inverts the layer graph, and one that reads the store")


main()
