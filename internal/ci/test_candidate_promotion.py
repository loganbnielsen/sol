#!/usr/bin/env python3
"""Regression tests for the release-candidate promotion decision.

The decision is what stops a release being published from its tag before the
authorized AWS and GCP qualification exists, and what stops a verdict for one
candidate promoting another. The failure modes are the point: no verdict, a
verdict for a different candidate, a missing or failing required provider, an
omitted or non-passing release-blocking row, a blocked or excluded row without a
reason, and a missing independent absence result must all refuse; a complete
verdict that refers to the exact candidate must allow promotion. These tests
establish the decision mechanics only -- they are not qualification evidence.
"""

from __future__ import annotations

import copy
import json
import os
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "internal" / "tooling" / "release"))

import promotion  # noqa: E402

checks = 0
failures = 0

CANDIDATE = {
    "version": "v0.1.0-alpha.9",
    "revision": "a" * 40,
    "bundle": "sol-v0.1.0-alpha.9-linux-x86_64.tar.gz",
    "bundle_sha256": "b" * 64,
    "runner_image": "ghcr.io/example/sol-migration-runner@sha256:" + "c" * 64,
}


def check(label: str, condition: bool) -> None:
    global checks, failures
    checks += 1
    if condition:
        print(f"  [OK]   {label}")
    else:
        print(f"  [FAIL] {label}")
        failures += 1


def verdict() -> dict:
    return {
        "candidate": promotion.identity(CANDIDATE),
        "providers": {
            "aws": {
                "verdict": "pass",
                "required_rows": ["B1", "I8"],
                "rows": [
                    {"id": "B1", "status": "pass"},
                    {"id": "I8", "status": "pass"},
                ],
                "teardown": {"absence_verdict": "pass", "evidence": "aws-inventory-verdict.txt"},
            },
            "gcp": {
                "verdict": "pass",
                "required_rows": ["B1"],
                "rows": [{"id": "B1", "status": "pass"}],
                "teardown": {"absence_verdict": "pass", "evidence": "gcp-inventory-verdict.txt"},
            },
        },
    }


def refuses(label: str, candidate, document) -> None:
    check(label, promotion.decide(candidate, document) != [])


def allows(label: str, candidate, document) -> None:
    reasons = promotion.decide(candidate, document)
    check(label, reasons == [])


def test_identity() -> None:
    allows("a complete verdict for the exact candidate is eligible", CANDIDATE, verdict())
    refuses("no verdict refuses", CANDIDATE, None)
    refuses(
        "a verdict for another revision refuses",
        CANDIDATE,
        {**verdict(), "candidate": {**promotion.identity(CANDIDATE), "revision": "d" * 40}},
    )
    refuses(
        "a verdict for another bundle refuses",
        CANDIDATE,
        {**verdict(), "candidate": {**promotion.identity(CANDIDATE), "bundle_sha256": "e" * 64}},
    )
    refuses(
        "a verdict for another runner refuses",
        CANDIDATE,
        {
            **verdict(),
            "candidate": {
                **promotion.identity(CANDIDATE),
                "runner_image": "ghcr.io/example/other@sha256:" + "f" * 64,
            },
        },
    )
    refuses("a candidate without a digest runner refuses", {**CANDIDATE, "runner_image": "latest"}, verdict())
    refuses("a threadbare candidate refuses", {"version": "v0.1.0"}, verdict())


def test_providers() -> None:
    refuses("a missing provider refuses", CANDIDATE, {**verdict(), "providers": {"aws": verdict()["providers"]["aws"]}})
    document = verdict()
    document["providers"]["gcp"]["verdict"] = "fail"
    refuses("a failing provider refuses", CANDIDATE, document)
    document = verdict()
    document["providers"]["gcp"]["verdict"] = "blocked"
    document["providers"]["gcp"]["reason"] = "quota"
    refuses("a blocked provider refuses", CANDIDATE, document)
    document = verdict()
    del document["providers"]["aws"]["teardown"]
    refuses("a provider without an independent absence result refuses", CANDIDATE, document)
    document = verdict()
    document["providers"]["aws"]["teardown"]["absence_verdict"] = "present"
    refuses("a provider whose absence result is not a pass refuses", CANDIDATE, document)


def test_rows() -> None:
    document = verdict()
    document["providers"]["aws"]["rows"][1]["status"] = "fail"
    refuses("a failing required row refuses", CANDIDATE, document)
    document = verdict()
    document["providers"]["aws"]["rows"][1]["status"] = "not_run"
    refuses("a not-run required row refuses", CANDIDATE, document)
    document = verdict()
    del document["providers"]["aws"]["rows"][1]
    refuses("an omitted required row refuses", CANDIDATE, document)
    document = verdict()
    document["providers"]["aws"]["required_rows"] = []
    refuses("a provider that names no required rows refuses", CANDIDATE, document)
    document = verdict()
    document["providers"]["aws"]["rows"].append({"id": "C9", "status": "blocked"})
    refuses("a blocked extra row without a reason refuses", CANDIDATE, document)
    document = verdict()
    document["providers"]["aws"]["rows"].append(
        {"id": "C9", "status": "blocked", "reason": "not reachable on this target"}
    )
    allows("a blocked extra row with a reason stays visible and does not block", CANDIDATE, document)
    document = verdict()
    document["providers"]["aws"]["rows"].append(
        {"id": "C9", "status": "excluded", "reason": "out of scope for this profile"}
    )
    allows("an excluded row with a reason stays visible and does not block", CANDIDATE, document)


def test_record() -> None:
    with tempfile.TemporaryDirectory() as directory:
        bundle = os.path.join(directory, "sol-v0.1.0-alpha.9-linux-x86_64.tar.gz")
        with open(bundle, "wb") as handle:
            handle.write(b"bundle")
        data = promotion.record(
            "v0.1.0-alpha.9", "a" * 40, bundle, CANDIDATE["runner_image"]
        )
        check("record names the built bundle", data["bundle"] == os.path.basename(bundle))
        check("record digests the built bundle", data["bundle_sha256"] == promotion.sha256_file(bundle))
        check("record keeps the runner digest", data["runner_image"] == CANDIDATE["runner_image"])
        try:
            promotion.record("v", "a" * 40, bundle, "latest")
        except promotion.InputError:
            check("record refuses a non-digest runner", True)
        else:
            check("record refuses a non-digest runner", False)
        promotion.verify_bundle(data, directory)
        check("verify accepts the recorded bundle", True)
        with open(bundle, "wb") as handle:
            handle.write(b"tampered")
        try:
            promotion.verify_bundle(data, directory)
        except promotion.InputError:
            check("verify refuses a bundle that is not the recorded one", True)
        else:
            check("verify refuses a bundle that is not the recorded one", False)
        with open(bundle, "wb") as handle:
            handle.write(b"bundle")
        os.remove(bundle)
        try:
            promotion.verify_bundle(data, directory)
        except promotion.InputError:
            check("verify refuses a missing recorded bundle", True)
        else:
            check("verify refuses a missing recorded bundle", False)


def test_command_line() -> None:
    with tempfile.TemporaryDirectory() as directory:
        candidate_path = os.path.join(directory, "candidate.json")
        verdict_path = os.path.join(directory, "verdict.json")
        with open(candidate_path, "w", encoding="utf-8") as handle:
            json.dump(CANDIDATE, handle)
        script = str(REPO / "internal" / "tooling" / "release" / "promotion.py")
        with open(verdict_path, "w", encoding="utf-8") as handle:
            json.dump(verdict(), handle)
        result = subprocess.run(
            [sys.executable, script, "decide", "--candidate", candidate_path, "--verdict", verdict_path],
            capture_output=True,
            text=True,
        )
        check("the command line allows a complete verdict", result.returncode == 0)
        stale = copy.deepcopy(verdict())
        stale["candidate"]["revision"] = "d" * 40
        with open(verdict_path, "w", encoding="utf-8") as handle:
            json.dump(stale, handle)
        result = subprocess.run(
            [sys.executable, script, "decide", "--candidate", candidate_path, "--verdict", verdict_path],
            capture_output=True,
            text=True,
        )
        check("the command line refuses a stale verdict", result.returncode == 1)
        check("and it names the mismatch", "different candidate" in result.stderr)
        same = subprocess.run(
            [sys.executable, script, "same", "--left", candidate_path, "--right", candidate_path],
            capture_output=True,
            text=True,
        )
        check("same accepts one candidate recorded twice", same.returncode == 0)
        different = subprocess.run(
            [sys.executable, script, "same", "--left", candidate_path, "--right", verdict_path],
            capture_output=True,
            text=True,
        )
        check("same refuses a candidate that moved", different.returncode == 1)
        recorded = subprocess.run(
            [sys.executable, script, "runner-image", "--candidate", candidate_path],
            capture_output=True,
            text=True,
        )
        check(
            "the command line prints the exact recorded runner digest",
            recorded.returncode == 0 and recorded.stdout.strip() == CANDIDATE["runner_image"],
        )
        tagged_path = os.path.join(directory, "tagged.json")
        with open(tagged_path, "w", encoding="utf-8") as handle:
            json.dump({**CANDIDATE, "runner_image": "ghcr.io/example/sol-migration-runner:latest"}, handle)
        tagged = subprocess.run(
            [sys.executable, script, "runner-image", "--candidate", tagged_path],
            capture_output=True,
            text=True,
        )
        check("the command line refuses a mutable tag as a runner identity", tagged.returncode == 2)


def main() -> int:
    print("release candidate promotion decision")
    test_identity()
    test_providers()
    test_rows()
    test_record()
    test_command_line()
    print(f"\n{checks - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
