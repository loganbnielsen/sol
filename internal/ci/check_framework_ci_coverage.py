#!/usr/bin/env python3
"""Every framework package's unit suite must run in CI.

A dune `(test ...)` stanza in `framework/ocaml/<pkg>/test/` is a suite CI is
expected to compile and run. Two ways this silently stops being true, both
observed: the package is left out of the workflow's unit step (sol-jobs), or the
package is left out because its test directory also builds a suite that needs
infrastructure, so `dune test <dir>` would run both (kafka-eio-service, until its
broker-requiring suite became an executable behind the runtest-integration
alias). The unit step is where a framework package's offline coverage actually
happens, so a package missing from it is coverage the PR gate does not have.

Structure, not text: the workflow is read as YAML and the dune files are read as
stanzas, so reformatting either cannot change the verdict.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
FRAMEWORK = ROOT / "framework" / "ocaml"
UNIT_STEP = "Unit tests (no broker/Postgres/Loki required)"

TEST_STANZA = re.compile(r"^\((tests?)\b", re.M)
DUNE_TEST_ARG = re.compile(r"dune test\b(.*)")


def unit_step_command() -> str:
    try:
        import yaml  # type: ignore[import-untyped]
    except ImportError:  # pragma: no cover
        sys.exit("check_framework_ci_coverage: PyYAML is required (internal/ci/requirements.txt)")

    workflow = yaml.safe_load(WORKFLOW.read_text())
    for job in workflow.get("jobs", {}).values():
        for step in job.get("steps", []):
            if step.get("name") == UNIT_STEP:
                command = step.get("run")
                if not isinstance(command, str):
                    sys.exit(f"check_framework_ci_coverage: {UNIT_STEP!r} has no `run` command")
                return command
    sys.exit(f"check_framework_ci_coverage: no step named {UNIT_STEP!r} in {WORKFLOW}")


def units_suites() -> dict[str, list[str]]:
    packages: dict[str, list[str]] = {}
    for dune in sorted(FRAMEWORK.glob("*/test/dune")):
        text = dune.read_text()
        names = re.findall(r"\((?:tests\n\s*\(names|test\n\s*\(name)\s+([^)\s]+)", text)
        if TEST_STANZA.search(text):
            packages[str(dune.parent.parent.relative_to(ROOT))] = names or ["<unnamed>"]
    return packages


def covered(command: str) -> set[str]:
    match = DUNE_TEST_ARG.search(command)
    if match is None:
        sys.exit(f"check_framework_ci_coverage: {UNIT_STEP!r} does not run `dune test`")
    return {arg.rstrip("/") for arg in match.group(1).split() if arg.startswith("framework/")}


def main() -> int:
    command = unit_step_command()
    covered_dirs = covered(command)
    missing = {
        package: names
        for package, names in units_suites().items()
        if package not in covered_dirs
    }
    if missing:
        for package, names in sorted(missing.items()):
            print(
                f"  [FAIL] {package} has a unit suite ({', '.join(names)}) but the "
                f"{UNIT_STEP!r} step does not run it"
            )
        print(
            "  Fix: add the package to that step's `dune test …`, or, if its test "
            "directory also builds a suite that needs infrastructure, make that suite "
            "an executable behind a runtest-integration alias (kafka-eio-service's shape)."
        )
        return 1
    print(
        f"framework CI coverage: {len(units_suites())} package(s) with unit suites, "
        f"all in the {UNIT_STEP!r} step"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
