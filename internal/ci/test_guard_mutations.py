#!/usr/bin/env python3
"""Each new guard must fail on the change it exists to prevent."""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
COPIED = [
    "platform/cloud/gcp/cluster/main.tf",
    "platform/cloud/gcp/cluster/variables.tf",
    "platform/cloud/aws/cluster/main.tf",
]


def scratch():
    tmp = Path(tempfile.mkdtemp(prefix="sol-guard-mutation-"))
    for relative in COPIED:
        source = ROOT / relative
        target = tmp / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(source, target)
    return tmp


def mutate(tmp, relative, old, new):
    path = tmp / relative
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"mutation anchor not found in {relative}: {old!r}")
    path.write_text(text.replace(old, new, 1))


def run(script, tmp):
    return subprocess.run(
        [sys.executable, str(ROOT / script), str(tmp)], capture_output=True, text=True
    )


def main():
    cases = []

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/gcp/cluster/main.tf",
        '  host                   = local.kubernetes_host',
        '  host                   = "https://${google_container_cluster.main.endpoint}"',
    )
    cases.append(("the provider configured from the cluster resource again", tmp, "substrate"))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/gcp/cluster/main.tf",
        "needs_kubernetes = var.in_cluster_layer && var.provisioner_bootstrap_admin",
        "needs_kubernetes = var.provisioner_bootstrap_admin",
    )
    cases.append(("the operation gate dropped from needs_kubernetes", tmp, "substrate"))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/gcp/cluster/main.tf",
        "resource \"kubernetes_cluster_role_binding\" \"provisioner_bootstrap_admin\" {\n"
        "  count = local.needs_kubernetes ? 1 : 0",
        "resource \"kubernetes_cluster_role_binding\" \"provisioner_bootstrap_admin\" {\n"
        "  count = 1",
    )
    cases.append(("an in-cluster object no longer gated", tmp, "substrate"))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/gcp/cluster/main.tf",
        'removed {\n  from = google_compute_default_service_account.default\n\n'
        "  lifecycle {\n    destroy = false\n  }\n}\n\n",
        "",
    )
    cases.append(("the legacy shared resource no longer relinquished", tmp, "shared"))

    tmp = scratch()
    mutate(
        tmp,
        "platform/cloud/gcp/cluster/main.tf",
        'data "google_compute_default_service_account" "default" {',
        'resource "google_compute_default_service_account" "default" {',
    )
    cases.append(("a project-wide resource managed by a target again", tmp, "shared"))

    failures = 0
    for label, tmp, which in cases:
        script = (
            "internal/ci/check_substrate_root_evaluable.py"
            if which == "substrate"
            else "internal/ci/check_project_shared_resources.py"
        )
        result = run(script, tmp)
        if result.returncode == 0:
            print(f"test_guard_mutations: guard ACCEPTED a mutation: {label}", file=sys.stderr)
            failures += 1
        else:
            print(f"  rejected: {label}")
    if failures:
        return 1
    print(
        "test_guard_mutations: both guards reject the change each exists to prevent -- a "
        "provider configured from the cluster, a dropped operation gate, an ungated "
        "in-cluster object, a relinquished address restored, and a shared resource managed "
        "again"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
