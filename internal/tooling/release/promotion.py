#!/usr/bin/env python3
"""Immutable release candidate identity and promotion eligibility.

A release tag builds exactly one candidate -- the release bundle and its
version-aligned migration-runner digest, tied to the tagged revision -- and
records it as a draft release. Nothing is published from the tag.

Promotion consumes that exact candidate. It refuses unless a qualification
verdict refers to the candidate by identity and reports the required AWS and
GCP rows passing, each with an independently observed absence verdict. The
verdict is produced by the explicitly operator-authorized live campaign; this
module makes no provider read and never treats a successful workflow, Sol's exit
code or Terraform state as qualification or absence evidence.

Candidate record:
  {"version": ..., "revision": ..., "bundle": ...,
   "bundle_sha256": ..., "runner_image": "<image>@sha256:<64 hex>"}

Qualification verdict:
  {"candidate": {"version": ..., "revision": ..., "bundle_sha256": ...,
                 "runner_image": ...},
   "providers": {"<name>": {"verdict": "pass"|"fail"|...,
                            "required_rows": ["B1", ...],
                            "rows": [{"id": ..., "status": ...,
                                      "reason": ..., "evidence": ...}],
                            "teardown": {"absence_verdict": "pass",
                                         "evidence": ...}}}}

Usage:
    promotion.py record --version V --revision R --bundle PATH
                        --runner-image IMAGE --out FILE
    promotion.py decide --candidate FILE --verdict FILE
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

IDENTITY_FIELDS = ("version", "revision", "bundle_sha256", "runner_image")
DIGEST = re.compile(r"@sha256:[0-9a-f]{64}$")
HEX64 = re.compile(r"[0-9a-f]{64}")
REQUIRED_PROVIDERS = ("aws", "gcp")


class InputError(Exception):
    pass


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load(path: str) -> object:
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError as exc:
        raise InputError(f"{path}: not found") from exc
    except json.JSONDecodeError as exc:
        raise InputError(f"{path}: not JSON: {exc}") from exc


def record(version: str, revision: str, bundle: str, runner_image: str) -> dict:
    if not version or not revision:
        raise InputError("record needs a version and a revision")
    if not os.path.isfile(bundle):
        raise InputError(f"record needs the built bundle, and {bundle} is not a file")
    if not DIGEST.search(runner_image or ""):
        raise InputError(
            f"runner image {runner_image!r} is not an <image>@sha256:<64 hex> reference"
        )
    return {
        "version": version,
        "revision": revision,
        "bundle": os.path.basename(bundle),
        "bundle_sha256": sha256_file(bundle),
        "runner_image": runner_image,
    }


def identity(record: dict) -> dict:
    return {field: record.get(field) for field in IDENTITY_FIELDS}


def verify_bundle(candidate: object, directory: str) -> None:
    """Raise unless the candidate's recorded bundle is present and matches its digest."""
    if not isinstance(candidate, dict):
        raise InputError("the candidate record is not a JSON object")
    name = candidate.get("bundle")
    digest = candidate.get("bundle_sha256")
    if not isinstance(name, str) or name == "":
        raise InputError("the candidate record names no bundle")
    path = os.path.join(directory, name)
    if not os.path.isfile(path):
        raise InputError(f"the recorded bundle {name} is not present in {directory}")
    actual = sha256_file(path)
    if actual != digest:
        raise InputError(
            f"the bundle {name} has sha256:{actual}, not the recorded sha256:{digest}"
        )


def decide(
    candidate: object, verdict: object | None, required_providers=REQUIRED_PROVIDERS
) -> list[str]:
    """Return the reasons this candidate may not be promoted; empty means eligible."""
    if not isinstance(candidate, dict):
        return ["the candidate record is not a JSON object"]
    reasons = []
    for field in IDENTITY_FIELDS:
        value = candidate.get(field)
        if not isinstance(value, str) or value == "":
            reasons.append(f"the candidate record has no {field!r}")
    if not DIGEST.search(candidate.get("runner_image") or ""):
        reasons.append("the candidate's migration-runner image is not a digest reference")
    if not HEX64.fullmatch(candidate.get("bundle_sha256") or ""):
        reasons.append("the candidate's bundle digest is not a sha256")
    if reasons:
        return reasons

    if verdict is None:
        return ["no qualification verdict is attached to the candidate"]
    if not isinstance(verdict, dict):
        return ["the qualification verdict is not a JSON object"]
    claimed = verdict.get("candidate")
    if not isinstance(claimed, dict):
        reasons.append("the qualification verdict names no candidate")
    elif identity(claimed) != identity(candidate):
        reasons.append(
            "the qualification verdict refers to a different candidate than this release"
        )
    providers = verdict.get("providers")
    if not isinstance(providers, dict):
        reasons.append("the qualification verdict names no providers")
        return reasons
    for provider in required_providers:
        reasons.extend(provider_reasons(provider, providers.get(provider)))
    return reasons


def provider_reasons(provider: str, entry: object) -> list[str]:
    if not isinstance(entry, dict):
        return [f"no {provider} qualification verdict"]
    reasons = []
    if entry.get("verdict") != "pass":
        reasons.append(f"the {provider} verdict is {entry.get('verdict')!r}, not 'pass'")
    teardown = entry.get("teardown")
    if not isinstance(teardown, dict) or teardown.get("absence_verdict") != "pass":
        reasons.append(
            f"the {provider} verdict has no independently observed passing absence result"
        )
    required = entry.get("required_rows")
    if not isinstance(required, list) or not required:
        reasons.append(f"the {provider} verdict names no release-blocking row set")
        required = []
    rows = entry.get("rows")
    if not isinstance(rows, list) or not rows:
        reasons.append(f"the {provider} verdict lists no rows")
        return reasons
    by_id: dict[str, dict] = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("id"), str) or row["id"] == "":
            reasons.append(f"the {provider} verdict has a row with no id")
            continue
        by_id[row["id"]] = row
        status = row.get("status")
        if status == "pass":
            continue
        if status in ("excluded", "blocked", "not_run"):
            if not isinstance(row.get("reason"), str) or row["reason"] == "":
                reasons.append(f"{provider} row {row['id']} is {status!r} without a reason")
            continue
        reasons.append(f"{provider} row {row['id']} is {status!r}, not 'pass'")
    for row_id in required:
        row = by_id.get(row_id)
        if row is None:
            reasons.append(f"the {provider} verdict omits release-blocking row {row_id}")
        elif row.get("status") != "pass":
            reasons.append(
                f"{provider} release-blocking row {row_id} is {row.get('status')!r}, not 'pass'"
            )
    return reasons


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    record_parser = commands.add_parser("record")
    record_parser.add_argument("--version", required=True)
    record_parser.add_argument("--revision", required=True)
    record_parser.add_argument("--bundle", required=True)
    record_parser.add_argument("--runner-image", required=True)
    record_parser.add_argument("--out", required=True)
    decide_parser = commands.add_parser("decide")
    decide_parser.add_argument("--candidate", required=True)
    decide_parser.add_argument("--verdict", required=True)
    same_parser = commands.add_parser("same")
    same_parser.add_argument("--left", required=True)
    same_parser.add_argument("--right", required=True)
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--candidate", required=True)
    verify_parser.add_argument("--dir", required=True)
    args = parser.parse_args(argv[1:])
    try:
        if args.command == "record":
            data = record(args.version, args.revision, args.bundle, args.runner_image)
            with open(args.out, "w", encoding="utf-8") as handle:
                json.dump(data, handle, indent=2, sort_keys=True)
                handle.write("\n")
            print(f"recorded candidate {data['version']} at {args.out}")
            return 0
        if args.command == "same":
            if load(args.left) == load(args.right):
                print(f"{args.left} and {args.right} record the same candidate")
                return 0
            print("the recorded candidate differs from the rebuilt one", file=sys.stderr)
            return 1
        if args.command == "verify":
            verify_bundle(load(args.candidate), args.dir)
            print("the recorded bundle matches the candidate identity")
            return 0
        candidate = load(args.candidate)
        verdict = load(args.verdict)
        reasons = decide(candidate, verdict)
        if reasons:
            print("promotion refused:", file=sys.stderr)
            for reason in reasons:
                print(f"  - {reason}", file=sys.stderr)
            return 1
        print(
            f"candidate {candidate['version']} ({candidate['revision']}) is eligible for promotion"
        )
        print(f"  bundle {candidate['bundle']} sha256:{candidate['bundle_sha256']}")
        print(f"  runner {candidate['runner_image']}")
        return 0
    except InputError as exc:
        print(f"promotion: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
