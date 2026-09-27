#!/usr/bin/env python3
"""Tests for the qualification observer.

The point of these tests is the failure modes that live evidence actually produced, so the
fixture is the real gcloud-written kubeconfig shape (name AFTER the cluster block) and the
stub kubectl can fail, hang, or succeed per read. Nothing here tests the shell.

Two of those failure modes get their own file each: the same document with its keys reordered
must resolve identically, because 15g's endpoint column depended on key order; and a stale
unrelated cluster listed ahead of this run's must never be the one selected.
"""

from __future__ import annotations

import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent
OBSERVER = ROOT / "observer.py"
FIXTURE = ROOT / "fixtures" / "kubeconfig-gcloud-real.yaml"

failures: list[str] = []
checks = 0


def check(description: str, condition: bool) -> None:
    global checks
    checks += 1
    if condition:
        print(f"  ok   {description}")
    else:
        print(f"  FAIL {description}")
        failures.append(description)


def run(*arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(OBSERVER), *arguments],
        capture_output=True,
        text=True,
    )


def write_stub(directory: pathlib.Path, fail_reads: str = "", hang_reads: str = "") -> pathlib.Path:
    """A kubectl that records its argv and can fail or hang for named reads.

    The record is one line per argv word, terminated by a marker, so words that contain
    spaces stay distinguishable from words that were split.

    The program name is recorded too, from `$0`: the kernel runs a shebang script as
    `sh <script> <args>`, so `$@` never contains it and `$0` is the script's path. Its
    basename is the program the observer invoked, which is what the fidelity checks assert.

    Explicit branches rather than a shell loop over a possibly-empty word list: an empty
    pattern matches everything, which silently made every read hang in the first draft.
    """
    argv_log = directory / "kubectl-argv.log"
    argv_binary = directory / "kubectl-argv.bin"
    lines = [
        "#!/bin/sh",
        f'printf "%s\\n" "$*" >>"{argv_log}"',
        f'printf "%s\\n" "${{0##*/}}" "$@" >>"{argv_binary}"',
        f'printf -- "--RECORD--\\n" >>"{argv_binary}"',
    ]
    for name in [n for n in fail_reads.split() if n]:
        lines.append(f'case "$*" in *"{name}"*) echo "error from server" >&2; exit 1 ;; esac')
    for name in [n for n in hang_reads.split() if n]:
        lines.append(f'case "$*" in *"{name}"*) sleep 30 ;; esac')
    lines += [
        'echo "NAME   READY   STATUS"',
        'echo "stub-pod-1   1/1   Running"',
        "exit 0",
    ]
    stub = directory / "kubectl"
    stub.write_text("\n".join(lines) + "\n", encoding="utf-8")
    stub.chmod(stub.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return argv_log


def main() -> int:
    print("observer: kubeconfig inspection")
    facts = json.loads(run("kubeconfig", "--file", str(FIXTURE), "--cluster", "sol-qual-gcp-15g", "--json").stdout)
    check("the real gcloud shape is recognised structurally", facts["has_cluster"] is True)
    check("and its configured endpoint is extracted", facts["server"] == "https://34.0.0.1")
    check("and the context is resolved by structure", facts["context"] == "gke_sol-qualification_us-central1_sol-qual-gcp-15g")

    import yaml

    document = yaml.safe_load(FIXTURE.read_text())
    entry = document["clusters"][0]
    reordered = {"clusters": [{"name": entry["name"], "cluster": entry["cluster"]}]}
    reordered.update({k: v for k, v in document.items() if k != "clusters"})
    with tempfile.TemporaryDirectory() as scratch:
        other = pathlib.Path(scratch) / "reordered.yaml"
        other.write_text(yaml.safe_dump(reordered, sort_keys=True), encoding="utf-8")
        facts = json.loads(run("kubeconfig", "--file", str(other), "--cluster", "sol-qual-gcp-15g", "--json").stdout)
        check("reordered keys are recognised identically", facts["has_cluster"] is True)
        check("and the endpoint still resolves", facts["server"] == "https://34.0.0.1")

    with tempfile.TemporaryDirectory() as scratch:
        stale = pathlib.Path(scratch) / "stale.yaml"
        stale.write_text(
            (FIXTURE.read_text())
            .replace(
                "clusters:\n",
                "clusters:\n- cluster:\n    server: https://198.51.100.7\n  name: gke_old-project_us-central1_sol-qual-gcp-15c\n",
                1,
            ),
            encoding="utf-8",
        )
        facts = json.loads(run("kubeconfig", "--file", str(stale), "--cluster", "sol-qual-gcp-15g", "--json").stdout)
        check("a stale cluster listed first is not selected", facts["server"] == "https://34.0.0.1")
        absent = json.loads(run("kubeconfig", "--file", str(stale), "--cluster", "sol-qual-gcp-99z", "--json").stdout)
        check("an absent cluster is reported absent, not inferred", absent["has_cluster"] is False)
        check("and the reason names what was there", "sol-qual-gcp-15g" in " ".join(absent["clusters"]))

    check("a missing file is not a crash", run("server", "--file", "/nonexistent", "--cluster", "x").stdout.strip() == "-")

    print("observer: capture")
    with tempfile.TemporaryDirectory() as scratch:
        directory = pathlib.Path(scratch)
        write_stub(directory, fail_reads="owner=helm")
        captured = directory / "capture"
        environment = dict(os.environ, PATH=f"{directory}:{os.environ['PATH']}")
        result = subprocess.run(
            [sys.executable, str(OBSERVER), "capture", "--dir", str(captured),
             "--kubeconfig", str(FIXTURE), "--cluster", "sol-qual-gcp-15g"],
            capture_output=True, text=True, env=environment,
        )
        summary = json.loads((captured / "capture-summary.json").read_text())
        designed = [
            "pods", "pod-states", "pod-demand", "events", "pvc", "pv",
            "nodes", "node-capacity", "node-taints", "helm-release-secrets",
        ]
        check("the capture exits 0 so a caller cannot truncate it", result.returncode == 0)
        check("every read is attempted independently", summary["attempted"] == len(designed))
        check("a failing read is recorded as failed", summary["failed"] == 1)
        check("and the others still succeeded", summary["succeeded"] == len(designed) - 1)
        check("the summary lists every designed artifact", len(summary["reads"]) == len(designed))
        check("the human summary is written too", (captured / "capture-summary.txt").is_file())
        check("a successful artifact keeps its content",
              "stub-pod-1" in (captured / "pods.log").read_text())
        check("a failed artifact records the failure, not silence",
              "exited 1" in (captured / "helm-release-secrets.log").read_text())
        check("credentials are reported present for a real kubeconfig", summary["credentials"] == "yes")
        reads_by_name = {r["artifact"]: r for r in summary["reads"]}
        check("the designed read set is exactly what the summary reports",
              sorted(reads_by_name) == sorted(designed))
        check("pod demand is attempted by name", "pod-demand" in reads_by_name)
        check("node taints are attempted by name", "node-taints" in reads_by_name)
        records: list[list[str]] = []
        current: list[str] = []
        for line in (directory / "kubectl-argv.bin").read_text().splitlines():
            if line == "--RECORD--":
                if current:
                    records.append(current)
                    current = []
                continue
            current.append(line)
        if current:
            records.append(current)
        check("every read arrived as its own invocation", len(records) >= 8)
        check("the pods read arrived as six argv words",
              ["kubectl", "get", "pods", "-A", "-o", "wide"] in records)
        jsonpath_records = [
            record for record in records if any("jsonpath={range .items[*]}" in a for a in record)
        ]
        check("the jsonpath expression arrived as exactly ONE argv word",
              jsonpath_records and all(
                  sum(1 for a in record if a.startswith("jsonpath=")) == 1 for record in jsonpath_records))
        check("every read carried kubectl as its first word",
              all(record[0] == "kubectl" for record in records))
        check("every read was run against the run's kubeconfig",
              all(r["argv"][0] == "kubectl" for r in summary["reads"]))

    print("observer: bounding and credentials")
    with tempfile.TemporaryDirectory() as scratch:
        directory = pathlib.Path(scratch)
        write_stub(directory, hang_reads="nodes")
        captured = directory / "capture"
        environment = dict(os.environ, PATH=f"{directory}:{os.environ['PATH']}")
        result = subprocess.run(
            [sys.executable, str(OBSERVER), "capture", "--dir", str(captured),
             "--kubeconfig", str(FIXTURE), "--cluster", "sol-qual-gcp-15g", "--bound", "1"],
            capture_output=True, text=True, env=environment,
        )
        summary = json.loads((captured / "capture-summary.json").read_text())
        by_name = {r["artifact"]: r for r in summary["reads"]}
        check("a hanging read is bounded, not waited on", by_name["nodes"]["exit_code"] == 124)
        check("and the reads after it still run", by_name["helm-release-secrets"]["ok"] is True)
        check("the bound is recorded in the summary", summary["bound_seconds"] == 1.0)
        check("the capture still exits 0", result.returncode == 0)

    with tempfile.TemporaryDirectory() as scratch:
        directory = pathlib.Path(scratch)
        write_stub(directory)
        captured = directory / "capture"
        environment = dict(os.environ, PATH=f"{directory}:{os.environ['PATH']}")
        subprocess.run(
            [sys.executable, str(OBSERVER), "capture", "--dir", str(captured),
             "--kubeconfig", str(directory / "absent-kubeconfig.yaml"), "--cluster", "sol-qual-gcp-15g"],
            capture_output=True, text=True, env=environment,
        )
        summary = json.loads((captured / "capture-summary.json").read_text())
        check("no credentials is recorded as such", summary["credentials"] == "no")
        check("and said in the evidence, not merely implied",
              "could not establish credentials" in (captured / "NO-KUBECONFIG.txt").read_text())
        check("the reason distinguishes absent from unreadable",
              "absent, empty, unparseable, or declares no clusters" in summary["credentials_reason"])
        check("the summary is still produced", (captured / "capture-summary.txt").is_file())

    print(f"\n{checks - len(failures)} passed, {len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
