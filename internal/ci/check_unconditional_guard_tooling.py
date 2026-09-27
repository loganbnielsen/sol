import pathlib
import re
import sys

import yaml

WORKFLOW = ".github/workflows/ci.yml"
JOB = "test"
BUILD_MARKER = "dune build"
ARTIFACT = re.compile(r"_build/default/([A-Za-z0-9_./-]+\.exe)")
SOLDEV_DEFAULT = re.compile(r"SOLDEV=\"\$\{SOLDEV:-([^}]+)\}")
SCRIPT_NAME = re.compile(r"[A-Za-z0-9_.-]+\.(?:sh|py)")
REQUIRED_TOOL = re.compile(r"command -v ([a-z0-9_.-]+)")
PROVIDED_BY_A_STEP = {
    "kubectl",
    "shfmt",
    "ocamlformat",
}
TICKET_VALIDATION = "Pipeline ticket validation guard"
REMEDY = "build it in a step with no `if:` above that guard"


def resolve(name, root):
    for candidate in (root / "internal/ci" / name, root / "internal/ci/lib" / name):
        if candidate.exists():
            return candidate
    return None


def reaches(root, start):
    seen, queue = set(), list(start)
    while queue:
        path = queue.pop()
        if path in seen:
            continue
        seen.add(path)
        for name in SCRIPT_NAME.findall(path.read_text(encoding="utf-8")):
            nxt = resolve(name, root)
            if nxt is not None and nxt not in seen:
                queue.append(nxt)
    return seen


def artifacts(root, scripts):
    found = set()
    for path in scripts:
        text = path.read_text(encoding="utf-8")
        for match in ARTIFACT.finditer(text):
            found.add(match.group(1))
        for match in SOLDEV_DEFAULT.finditer(text):
            found.add(match.group(1).replace("$ROOT/", "").replace("_build/default/", ""))
    return found


def provides(step, artifact):
    run = str(step.get("run", ""))
    return BUILD_MARKER in run and artifact in run


INSTALLS = re.compile(r"curl|wget|apt-get|apt install|opam install|pip install|go install|\binstall\b")


def provides_tool(root, step, tool):
    named = SCRIPT_NAME.findall(str(step.get("run", "")))
    scripts = [p for p in (resolve(n, root) for n in named) if p is not None]
    for path in reaches(root, scripts):
        for line in path.read_text(encoding="utf-8").split("\n"):
            if tool in line and INSTALLS.search(line):
                return True
    for line in str(step.get("run", "")).split("\n"):
        if tool in line and INSTALLS.search(line):
            return True
    return False


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    steps = yaml.safe_load((root / WORKFLOW).read_text(encoding="utf-8"))["jobs"][JOB]["steps"]
    unconditional = [(i, step) for i, step in enumerate(steps, 1) if not step.get("if")]
    failures = []

    for i, step in unconditional:
        named = SCRIPT_NAME.findall(str(step.get("run", "")))
        scripts = [p for p in (resolve(n, root) for n in named) if p is not None]
        if not scripts:
            continue
        for tool in sorted(
            {
                tool
                for path in reaches(root, scripts)
                for tool in REQUIRED_TOOL.findall(path.read_text(encoding="utf-8"))
                if tool in PROVIDED_BY_A_STEP
            }
        ):
            provider = next(
                (j for j, candidate in unconditional if j < i and provides_tool(root, candidate, tool)),
                None,
            )
            if provider is None:
                failures.append(
                    f"step {i} ({step.get('name')}) runs unconditionally and requires "
                    f"{tool}, which no earlier unconditional step provides -- {REMEDY}"
                )
        for artifact in sorted(artifacts(root, reaches(root, scripts))):
            provider = next(
                (j for j, candidate in unconditional if j < i and provides(candidate, artifact)),
                None,
            )
            if provider is None:
                failures.append(
                    f"step {i} ({step.get('name')}) runs unconditionally and needs "
                    f"{artifact}, which no earlier unconditional step builds -- {REMEDY}"
                )

    validated = [
        i for i, step in unconditional if TICKET_VALIDATION in str(step.get("name", ""))
    ]
    if not validated:
        failures.append(
            f"no step named {TICKET_VALIDATION!r} runs without an `if:` -- a ticket change is a "
            f"docs-only change, so gating it is how the whole tree stops being validated"
        )

    for failure in failures:
        print(f"check_unconditional_guard_tooling: {failure}", file=sys.stderr)
    if failures:
        return 1
    print(
        f"check_unconditional_guard_tooling: {len(unconditional)} unconditional step(s) checked; "
        f"every guard's tooling is built before it runs"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
