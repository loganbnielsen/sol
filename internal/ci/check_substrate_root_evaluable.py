#!/usr/bin/env python3
"""A substrate resource must stay evaluable when its cluster is gone.

The GCP cluster root declares a Kubernetes provider whose cluster is created by the same
root. Terraform configures that provider for operations that evaluate the whole
configuration -- `import` among them -- so while the provider was configured from the
cluster's own attributes, a substrate resource could not be adopted into Terraform
ownership once the cluster was absent (FND-0070, Attempt 25).

The fix is an operation-scoped gate: `in_cluster_layer` (with `provisioner_bootstrap_admin`)
drives `local.needs_kubernetes`, and when it is false the provider's values are the empty
string -- a *known* value -- so the configuration stays evaluable. This guard holds that
shape: the provider must take its values from the gated locals, the locals must be gated,
and every in-cluster object in the root must carry the same gate. The behavioural half is
`check_substrate_root_evaluable.sh` (terraform console), wired next to this in CI.
"""
import re
import sys
from pathlib import Path

NAME = "check_substrate_root_evaluable"

ROOT = "platform/cloud/gcp/cluster"
PROVIDER_VALUES = ["host", "token", "cluster_ca_certificate"]
CLUSTER_SOURCED = ["kubernetes_host", "kubernetes_cluster_ca_certificate"]

LOCALS = {
    "kubernetes_host": "local.needs_kubernetes",
    "kubernetes_token": "local.needs_kubernetes",
    "kubernetes_cluster_ca_certificate": "local.needs_kubernetes",
}


def block(text, marker):
    start = text.index(marker)
    depth = 0
    index = start
    while index < len(text):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]
        index += 1
    raise ValueError(f"unbalanced braces from {marker}")


def main(argv):
    root = Path(argv[1]) if len(argv) > 1 else Path(".")
    directory = root / ROOT
    problems = []
    if not directory.exists():
        print(f"{NAME}: the GCP cluster root is missing at {directory}", file=sys.stderr)
        return 1
    text = "\n".join(tf.read_text() for tf in sorted(directory.glob("*.tf")))

    try:
        provider = block(text, 'provider "kubernetes"')
    except ValueError:
        print(f"{NAME}: no kubernetes provider block in the GCP cluster root", file=sys.stderr)
        return 1

    for attribute in PROVIDER_VALUES:
        local = f"kubernetes_{attribute}"
        if re.search(rf"^\s*{attribute}\s*=\s*local\.{local}\s*$", provider, re.M) is None:
            problems.append(
                f"the kubernetes provider's {attribute} must come from local.{local}, which is "
                "gated: configured straight from the cluster's attributes it is unknown while "
                "the cluster is absent, and then Terraform refuses to evaluate the root at all "
                "(FND-0070)"
            )

    for local in LOCALS:
        match = re.search(
            rf"^\s*{local}\s*=(?P<body>.*?)\n(?:\s*[a-z_]+\s*=|\}}\s*$)", text, re.M | re.S
        )
        body = match.group("body") if match else ""
        if "data.google_container_cluster" in body:
            problems.append(
                f"local.{local} reads the cluster through a data source: that is resolved when "
                "the configuration is evaluated, so an apply that creates the cluster cannot "
                "defer it and fails before the cluster exists (FND-0070)"
            )

    for local in CLUSTER_SOURCED:
        match = re.search(
            rf"^\s*{local}\s*=(?P<body>.*?)\n(?:\s*[a-z_]+\s*=|\}}\s*$)", text, re.M | re.S
        )
        body = match.group("body") if match else ""
        if "google_container_cluster.main" not in body:
            problems.append(
                f"local.{local} must derive from google_container_cluster.main: a managed "
                "resource's attribute is deferrable, which is what lets the bootstrap binding be "
                "created in the same apply that creates the cluster (FND-0070)"
            )

    for local, gate in LOCALS.items():
        pattern = rf"^\s*{local}\s*=.*{re.escape(gate)}" 
        if re.search(pattern, text, re.M | re.S) is None:
            problems.append(
                f"local.{local} must be gated on {gate} so it is a known empty value when the "
                "in-cluster layer is off"
            )

    if re.search(r"^\s*needs_kubernetes\s*=\s*var\.in_cluster_layer\s*$", text, re.M) is None:
        problems.append(
            "local.needs_kubernetes must be var.in_cluster_layer: the layer is the operation-scoped "
            "input, and the provider must be configured whenever the in-cluster graph is part of "
            "the operation -- including the apply that *removes* the bootstrap binding, which is "
            "a delete through that provider and fails against an empty host (FND-0070)"
        )

    if re.search(r'^variable\s+"in_cluster_layer"', text, re.M) is None:
        problems.append(
            "the root must declare variable \"in_cluster_layer\" with an operation-scoped "
            "description, defaulting to true so ordinary applies are unchanged"
        )

    for match in re.finditer(
        r'^resource\s+"(?P<type>kubernetes_[a-z0-9_]+|helm_[a-z0-9_]+)"\s+"[a-z0-9_]+"',
        text,
        re.M,
    ):
        start = match.start()
        window = text[start : start + 400]
        if "local.needs_kubernetes" not in window:
            problems.append(
                f"the in-cluster resource {match.group('type')} must be gated on "
                "local.needs_kubernetes, so it cannot be planned while the layer is off"
            )

    if problems:
        for problem in problems:
            print(f"{NAME}: {problem}", file=sys.stderr)
        return 1
    print(
        f"{NAME}: the GCP cluster root's Kubernetes provider takes all of its values from "
        "locals gated on the operation-scoped in_cluster_layer input, and its in-cluster "
        "objects carry the same gate"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
