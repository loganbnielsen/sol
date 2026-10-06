"""Pin the workflow contract the merge queue depends on.

A merge queue only merges when the required check reports on the synthetic
merge-group revision. That is a property of the workflow rather than of any
change, and pull-request CI cannot observe it: losing the trigger or gating the
required job shows up as a stalled queue, not a failed check. Assert the
contract here so a regression fails loudly instead.

The check is deliberately about the merge-group event, not about the queue
itself: disabling the queue must not require editing this guard.
"""

import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is not installed: pip install -r internal/ci/requirements.txt")

NAME = "check_ci_merge_group"
REQUIRED_JOB = "test"


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[2])
    path = root / ".github/workflows/ci.yml"
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    # PyYAML's YAML 1.1 boolean key: the bare `on:` workflow key loads as True.
    triggers = document.get("on", document.get(True))
    jobs = document.get("jobs", {}) or {}
    problems = []

    if not isinstance(triggers, dict) or "pull_request" not in triggers:
        problems.append("ci.yml no longer triggers on pull_request")
    if not isinstance(triggers, dict) or "merge_group" not in triggers:
        problems.append(
            "ci.yml does not trigger on merge_group, so a queued pull request would never "
            "report the required check and the merge queue would stall"
        )

    required = jobs.get(REQUIRED_JOB)
    if not isinstance(required, dict):
        problems.append(f"ci.yml has no `{REQUIRED_JOB}` job, which branch protection requires")
    else:
        condition = str(required.get("if", ""))
        if "always()" not in condition:
            problems.append(
                f"the required `{REQUIRED_JOB}` job's if-condition is {condition!r}; a required "
                "check must always run or it is left unreported"
            )
        for token in ("github.event_name", "pull_request", "merge_group"):
            if token in condition:
                problems.append(
                    f"the required `{REQUIRED_JOB}` job's if-condition references {token!r}, so "
                    "it can be skipped for an event and leave the check unreported"
                )

    classify = jobs.get("classify", {})
    run = "\n".join(
        str(step["run"])
        for step in (classify.get("steps", []) if isinstance(classify, dict) else [])
        if isinstance(step, dict) and "run" in step
    )
    for token in (
        "github.event.pull_request.base.sha",
        "github.event.pull_request.head.sha",
        "github.event.merge_group.base_sha",
        "github.event.merge_group.head_sha",
    ):
        if token not in run:
            problems.append(
                f"the classify step does not select {token!r}, so it cannot classify both "
                "pull_request and merge_group"
            )

    if problems:
        for problem in problems:
            print(f"{NAME}: {problem}", file=sys.stderr)
        sys.exit(f"{NAME}: the workflow no longer satisfies the merge queue's required-check contract")

    print(
        f"{NAME}: ci.yml triggers on pull_request and merge_group, the required "
        f"`{REQUIRED_JOB}` job always runs, and classification selects each event's own range"
    )


main()
