import os
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is not installed: pip install -r internal/ci/requirements.txt")

INVOKED = re.compile(r"^(internal|platform)/[A-Za-z0-9_/.-]*\.sh$")
USES_RG = re.compile(r"(^|[^A-Za-z0-9_])rg\s")
NAME = "check_workflow_paths"


def walk(node, key_name):
    if isinstance(node, yaml.MappingNode):
        for key, value in node.value:
            if isinstance(key, yaml.ScalarNode) and key.value == key_name:
                yield value
            yield from walk(value, key_name)
    elif isinstance(node, yaml.SequenceNode):
        for item in node.value:
            yield from walk(item, key_name)


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[2])
    workflows = root / ".github/workflows"
    if not workflows.is_dir():
        sys.exit(f"{NAME}: no workflow directory at {workflows}")
    problems = []
    entries = []
    scripts = set()
    for path in sorted(list(workflows.glob("*.yml")) + list(workflows.glob("*.yaml"))):
        with open(path, encoding="utf-8") as f:
            document = yaml.compose(f)
        rel = path.relative_to(root)
        for paths in walk(document, "paths"):
            if isinstance(paths, yaml.SequenceNode):
                entries += [(f"{rel}:{item.start_mark.line + 1}", item.value) for item in paths.value]
        for run in walk(document, "run"):
            if isinstance(run, yaml.ScalarNode):
                for line in run.value.splitlines():
                    words = line.split()
                    if words and INVOKED.match(words[0]):
                        scripts.add(words[0])
    for script in sorted(scripts):
        target = root / script
        if not os.access(target, os.X_OK):
            problems.append(
                f"the workflow runs '{script}', which is not executable\n"
                f"  a direct invocation exits 126; make it executable, or invoke it as 'bash {script}'"
            )
        if target.is_file() and USES_RG.search(target.read_text(encoding="utf-8", errors="replace")):
            problems.append(f"'{script}' calls rg, which CI runners do not have\n  use grep (rg is not part of the runner image)")
    checked = 0
    for where, entry in entries:
        if entry.startswith("!"):
            continue
        checked += 1
        if any(c in entry for c in "*?["):
            prefix = re.split(r"[*?\[]", entry, 1)[0]
            prefix_dir = prefix.rsplit("/", 1)[0] if "/" in prefix else "."
            if not (root / prefix_dir).is_dir():
                problems.append(f"{where}: '{entry}' -- its directory '{prefix_dir}' does not exist")
                continue
            tracked = subprocess.run(
                ["git", "-C", str(root), "ls-files", "--", f":(glob){entry}"], capture_output=True, text=True
            ).stdout
            if not tracked.strip():
                problems.append(f"{where}: '{entry}' matches no tracked file")
        elif not (root / entry).exists():
            problems.append(f"{where}: '{entry}' does not exist")
    for problem in problems:
        print(f"{NAME}: {problem}", file=sys.stderr)
    if problems:
        sys.exit(
            f"{NAME}: a paths: filter names something that is gone, so its workflow would silently stop triggering"
        )
    print(
        f"{NAME}: {checked} paths: filter entr(y/ies) checked, all naming something in the repository; "
        f"{len(scripts)} directly invoked script(s) checked, all executable and none reaching for rg"
    )


main()
