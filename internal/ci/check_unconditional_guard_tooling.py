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
FULL = "needs.classify.outputs.kind != 'docs-only' || steps.docs_tooling.outputs.cache-hit != 'true'"
FAST = "needs.classify.outputs.kind == 'docs-only' && steps.docs_tooling.outputs.cache-hit == 'true'"
REMEDY = "provide it earlier on the same execution path"


def runs_on(step, fast):
    condition = step.get("if", "")
    if not condition:
        return True
    if condition in (FULL, "needs.classify.outputs.kind != 'docs-only'"):
        return not fast
    if condition == FAST:
        return fast
    if condition == "needs.classify.outputs.kind == 'docs-only'":
        return fast
    return False


def resolve(name, root):
    for candidate in (
        root / "internal/ci" / name,
        root / "internal/ci/lib" / name,
        root / "internal/tooling/scripts" / name,
    ):
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
    failures = []
    cache = next((step for step in steps if step.get("id") == "docs_tooling"), {})
    cache_settings = cache.get("with", {})
    if (
        cache.get("uses") != "actions/cache/restore@v4"
        or cache.get("if") != "needs.classify.outputs.kind == 'docs-only'"
        or cache_settings.get("path") != "_build/default/internal/tooling/soldev/bin/main.exe"
        or "hashFiles(" not in cache_settings.get("key", "")
        or "internal/tooling/soldev/**/*.ml" not in cache_settings.get("key", "")
    ):
        failures.append("docs-only validator must restore a main-built validator keyed on soldev")
    saved = [step for step in steps if step.get("uses") == "actions/cache/save@v4"]
    if not any(
        step.get("with", {}).get("path") == cache_settings.get("path")
        and step.get("with", {}).get("key") == cache_settings.get("key")
        and step.get("if") == "github.event_name == 'push' && github.ref == 'refs/heads/main'"
        for step in saved
    ):
        failures.append("the validator cache must be saved only by trusted main pushes with the same key")
    for fast in (False, True):
        active = [(i, step) for i, step in enumerate(steps, 1) if runs_on(step, fast)]
        inspect_path(root, active, fast, failures)
    for failure in failures:
        print(f"check_unconditional_guard_tooling: {failure}", file=sys.stderr)
    if failures:
        return 1
    print("check_unconditional_guard_tooling: full and cached docs-only paths have tooling and ticket validation")
    return 0


def inspect_path(root, active, fast, failures):
    for i, step in active:
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
                (j for j, candidate in active if j < i and provides_tool(root, candidate, tool)),
                None,
            )
            if provider is None:
                failures.append(
                    f"step {i} ({step.get('name')}) requires "
                    f"{tool}, which no earlier unconditional step provides -- {REMEDY}"
                )
        for artifact in sorted(artifacts(root, reaches(root, scripts))):
            provider = next(
                (j for j, candidate in active if j < i and (
                    provides(candidate, artifact)
                    or (fast and candidate.get("id") == "docs_tooling"
                        and candidate.get("with", {}).get("path") == f"_build/default/{artifact}")
                )),
                None,
            )
            if provider is None:
                failures.append(
                    f"step {i} ({step.get('name')}) needs "
                    f"{artifact}, which no earlier unconditional step builds -- {REMEDY}"
                )

    validated = [
        i for i, step in active if (
            TICKET_VALIDATION in str(step.get("name", ""))
            or "pipeline validate" in str(step.get("run", ""))
        )
    ]
    if not validated:
        failures.append(
            f"no ticket validation runs on the {'cached docs-only' if fast else 'full/cache-miss'} path"
        )


if __name__ == "__main__":
    sys.exit(main())
