#!/usr/bin/env python3
"""Structured observer for a GCP qualification run.

This is the part of the qualification harness where shell was the wrong tool. Every
evidence loss in attempts 15c-15g came from shell control flow or textual parsing:

  * a kubeconfig entry found by YAML key order rather than structure;
  * `set -e` ending a waiter on a read that failed while the cluster did not exist;
  * `set -e` ending a capture after one failed read, losing the rest;
  * a jsonpath expression split into several argv words by quoting;
  * reads that could wait forever against an unreachable API;
  * a summary never written because an earlier step aborted.

Shell still orchestrates: `live-qual.sh` invokes gcloud, Terraform, Sol and teardown,
and owns the run's sequence. This module owns the stateful, structured parts -- reading a
kubeconfig, running a bounded capture, and accounting for what each read did -- and it is
written so that a failing read is recorded rather than fatal.

Every capture read is declared as an argv vector rather than a command string. The two
jsonpath expressions contain spaces and braces, and are meant to arrive as ONE argv word;
building the vector at a call site by string interpolation is how 15g split them.

`capture` exits 0 whenever the capture ran and accounted for every read. A read that
failed on the cluster is data, not a process failure: exiting non-zero there is what ended
the shell capture after one failed read and lost the other seven.

Usage:
    observer.py kubeconfig --file F --cluster C [--json]
    observer.py capture --dir D --kubeconfig F --cluster C [--bound 30]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover - the dependency is pinned in requirements.txt
    yaml = None


JSONPATH_POD_STATES = (
    "jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}"
    '\t{.status.phase}\t{.spec.nodeName}\t'
    '{range .status.containerStatuses[*]}{.name}={.state}{.lastState}'
    ' restarts={.restartCount} {end}{"\\n"}{end}'
)

JSONPATH_NODE_CAPACITY = (
    "jsonpath={range .items[*]}{.metadata.name}"
    '\tallocatable={.status.allocatable.cpu}/{.status.allocatable.memory}\t'
    '{range .status.conditions[*]}{.type}={.status} {end}{"\\n"}{end}'
)

CAPTURE_READS: list[tuple[str, list[str]]] = [
    ("pods", ["get", "pods", "-A", "-o", "wide"]),
    ("pod-states", ["get", "pods", "-A", "-o", JSONPATH_POD_STATES]),
    ("events", ["get", "events", "-A", "--sort-by=.lastTimestamp"]),
    ("pvc", ["get", "pvc", "-A", "-o", "wide"]),
    ("pv", ["get", "pv", "-o", "wide"]),
    ("nodes", ["get", "nodes", "-o", "wide"]),
    ("node-capacity", ["get", "nodes", "-o", JSONPATH_NODE_CAPACITY]),
    (
        "helm-release-secrets",
        [
            "get",
            "secrets",
            "-A",
            "-l",
            "owner=helm",
            "-o",
            "custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.type",
        ],
    ),
]


def load_kubeconfig(path: str) -> dict[str, Any]:
    """Parse a kubeconfig. Returns {} when it cannot be read or is not a mapping.

    Key order is irrelevant here: real gcloud-written files put `name:` after the
    cluster block, which a shell regular expression quietly failed to match.
    """
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return {}
    if yaml is None:
        raise SystemExit("observer.py needs PyYAML (internal/ci/requirements.txt)")
    try:
        document = yaml.safe_load(text)
    except yaml.YAMLError:
        return {}
    if not isinstance(document, dict):
        return {}
    return document


def cluster_names(document: dict[str, Any]) -> list[str]:
    entries = document.get("clusters")
    if not isinstance(entries, list):
        return []
    names = []
    for entry in entries:
        if isinstance(entry, dict) and isinstance(entry.get("name"), str):
            names.append(entry["name"])
    return names


def server_for_cluster(document: dict[str, Any], cluster: str) -> str | None:
    """The server of the entry whose name contains `cluster`, by structure not position."""
    entries = document.get("clusters")
    if not isinstance(entries, list):
        return None
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        name = entry.get("name")
        body = entry.get("cluster")
        if not isinstance(name, str) or cluster not in name:
            continue
        if isinstance(body, dict) and isinstance(body.get("server"), str):
            return body["server"]
    return None


def context_for_cluster(document: dict[str, Any], cluster: str) -> str | None:
    """A context whose cluster or name refers to `cluster`, current one preferred."""
    contexts = document.get("contexts")
    if not isinstance(contexts, list):
        return None
    current = document.get("current-context")
    matching = []
    for entry in contexts:
        if not isinstance(entry, dict):
            continue
        name = entry.get("name")
        body = entry.get("context")
        if not isinstance(name, str):
            continue
        refers = cluster in name
        if isinstance(body, dict) and isinstance(body.get("cluster"), str):
            refers = refers or cluster in body["cluster"]
        if refers:
            matching.append(name)
    if isinstance(current, str) and current in matching:
        return current
    return matching[0] if matching else None


def inspect(path: str, cluster: str) -> dict[str, Any]:
    document = load_kubeconfig(path)
    names = cluster_names(document)
    if not names:
        return {
            "has_cluster": False,
            "reason": "the file is absent, empty, unparseable, or declares no clusters",
            "server": None,
            "context": None,
            "clusters": [],
        }
    server = server_for_cluster(document, cluster)
    if server is None:
        return {
            "has_cluster": False,
            "reason": f"no cluster entry names {cluster}",
            "server": None,
            "context": None,
            "clusters": names,
        }
    return {
        "has_cluster": True,
        "reason": "",
        "server": server,
        "context": context_for_cluster(document, cluster),
        "clusters": names,
    }


def run_read(command: list[str], bound: float, env: dict[str, str]) -> tuple[int, str, str]:
    """Run one read under a bound. Never raises: a failure is data."""
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=bound,
            env=env,
        )
    except subprocess.TimeoutExpired as expired:
        partial = expired.stdout or ""
        if isinstance(partial, bytes):  # pragma: no cover - text=True keeps it a str
            partial = partial.decode("utf-8", "replace")
        return 124, partial, f"timed out after {bound:g}s"
    except OSError as error:
        return 127, "", f"could not run {command[0]}: {error}"
    return completed.returncode, completed.stdout, completed.stderr


def capture(directory: str, kubeconfig: str, cluster: str, bound: float) -> int:
    """Attempt every read, keep what each produced, and account for all of it.

    Returns 0 whenever the capture ran and accounted for every read -- a read that failed
    on the cluster is recorded in its artifact and in the summary, never fatal.
    """
    os.makedirs(directory, exist_ok=True)
    facts = inspect(kubeconfig, cluster)
    credentials = "yes" if facts["has_cluster"] else "no"

    if not facts["has_cluster"]:
        with open(os.path.join(directory, "NO-KUBECONFIG.txt"), "w", encoding="utf-8") as handle:
            handle.write(
                f"Qualification capture could not establish credentials for cluster {cluster}.\n"
                f"Reason: {facts['reason']}.\n"
                f"Clusters present: {', '.join(facts['clusters']) or 'none'}.\n"
                "Every Kubernetes read below ran without a context for this run and proves\n"
                "nothing about this cluster; they are recorded because a capture failure must\n"
                "be visible, not because their content is evidence.\n"
                "A failed capture is never evidence of absence.\n"
            )

    env = dict(os.environ)
    env["KUBECONFIG"] = kubeconfig

    results = []
    for name, arguments in CAPTURE_READS:
        artifact = os.path.join(directory, f"{name}.log")
        started = time.monotonic()
        code, stdout, stderr = run_read(["kubectl", *arguments], bound, env)
        elapsed = round(time.monotonic() - started, 2)
        ok = code == 0
        with open(artifact, "w", encoding="utf-8") as handle:
            handle.write(stdout)
            if not ok:
                handle.write(
                    f"\n[qualification capture: `kubectl {' '.join(arguments)}` exited {code}]\n"
                    f"[stderr: {stderr.strip()[:2000]}]\n"
                )
        results.append(
            {
                "artifact": name,
                "argv": ["kubectl", *arguments],
                "exit_code": code,
                "ok": ok,
                "lines": len([line for line in stdout.splitlines() if line.strip()]),
                "bytes": len(stdout),
                "seconds": elapsed,
                "stderr": stderr.strip()[:400],
            }
        )

    summary = {
        "cluster": cluster,
        "kubeconfig": kubeconfig,
        "credentials": credentials,
        "credentials_reason": facts["reason"],
        "configured_server": facts.get("server"),
        "bound_seconds": bound,
        "reads": results,
        "attempted": len(results),
        "succeeded": sum(1 for r in results if r["ok"]),
        "failed": sum(1 for r in results if not r["ok"]),
    }
    with open(os.path.join(directory, "capture-summary.json"), "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, sort_keys=True)
        handle.write("\n")
    with open(os.path.join(directory, "capture-summary.txt"), "w", encoding="utf-8") as handle:
        handle.write(f"credentials for {cluster}: {credentials}\n")
        if facts["reason"]:
            handle.write(f"credentials reason: {facts['reason']}\n")
        handle.write(f"reads attempted: {summary['attempted']}\n")
        for result in results:
            if result["ok"]:
                handle.write(f"{result['artifact']:<22} {result['lines']} lines\n")
            else:
                handle.write(f"{result['artifact']:<22} FAILED (rc {result['exit_code']}, {result['seconds']}s)\n")

    for result in results:
        state = "ok" if result["ok"] else f"FAILED rc={result['exit_code']}"
        print(f"  {result['artifact']}: {state} ({result['lines']} lines)", flush=True)
    print(f"  capture summary: {summary['succeeded']}/{summary['attempted']} reads produced output", flush=True)

    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    inspect_parser = subparsers.add_parser("kubeconfig")
    inspect_parser.add_argument("--file", required=True)
    inspect_parser.add_argument("--cluster", required=True)
    inspect_parser.add_argument("--json", action="store_true")

    server_parser = subparsers.add_parser("server")
    server_parser.add_argument("--file", required=True)
    server_parser.add_argument("--cluster", required=True)

    capture_parser = subparsers.add_parser("capture")
    capture_parser.add_argument("--dir", required=True)
    capture_parser.add_argument("--kubeconfig", required=True)
    capture_parser.add_argument("--cluster", required=True)
    capture_parser.add_argument("--bound", type=float, default=30.0)

    arguments = parser.parse_args(argv)

    if arguments.command == "kubeconfig":
        facts = inspect(arguments.file, arguments.cluster)
        if arguments.json:
            print(json.dumps(facts, sort_keys=True))
        elif facts["has_cluster"]:
            print(f"ok server={facts['server']} context={facts['context']}")
        else:
            print(f"no {facts['reason']}")
        return 0 if facts["has_cluster"] else 1

    if arguments.command == "server":
        facts = inspect(arguments.file, arguments.cluster)
        print(facts["server"] if facts["server"] else "-")
        return 0

    return capture(arguments.dir, arguments.kubeconfig, arguments.cluster, arguments.bound)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
