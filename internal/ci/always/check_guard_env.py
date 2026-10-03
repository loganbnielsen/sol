"""Classify every optional environment input a guard script reads.

A guard that weakens itself when an environment variable is set is an opt-out:
the environment the gate runs in can choose the guard's weaker branch. The
class runner removes every `clear` entry before it runs a member, so the
canonical path cannot select that branch, and this check fails on any guard
input that is neither cleared there nor explicitly recorded as a benign `read`.
An unclassified input is surfaced here rather than trusted by convention.
"""

import re
import sys
from pathlib import Path

VERDICTS = ("clear", "read")

STOCK_ENVIRONMENT = {
    "PATH",
    "HOME",
    "TMPDIR",
    "LANG",
    "LANGUAGE",
    "LC_ALL",
    "LC_CTYPE",
    "TERM",
    "SHELL",
    "USER",
    "PWD",
}

SHELL_READ = re.compile(r"\$\{([A-Z][A-Z0-9_]*)(?::-|-)")
PYTHON_READ = re.compile(
    r"""(?:os\.environ\.get|os\.getenv)\(\s*["']([A-Z][A-Z0-9_]*)["']"""
    r"""|os\.environ\[\s*["']([A-Z][A-Z0-9_]*)["']"""
)
ASSIGNMENT = re.compile(r"^(?:export[ \t]+)?([A-Z][A-Z0-9_]*)[ \t]*=(.*)$")


def shell_reads(text):
    names = set(SHELL_READ.findall(text))
    computed = set()
    for line in text.splitlines():
        match = ASSIGNMENT.match(line)
        if match and "${" + match.group(1) not in match.group(2):
            computed.add(match.group(1))
    return {name for name in names if name not in computed and name not in STOCK_ENVIRONMENT}


def python_reads(text):
    names = set()
    for match in PYTHON_READ.finditer(text):
        names.add(match.group(1) or match.group(2))
    return {name for name in names if name not in STOCK_ENVIRONMENT}


def guard_paths(root):
    directories = [root / "internal" / "ci", root / "internal" / "ci" / "always"]
    for directory in directories:
        if not directory.is_dir():
            continue
        for path in sorted(directory.iterdir()):
            if not path.is_file():
                continue
            if path.name.startswith("check_"):
                yield path


def discovered(root):
    found = {}
    for path in guard_paths(root):
        if path.name == Path(__file__).name:
            continue
        text = path.read_text(encoding="utf-8")
        names = python_reads(text) if path.suffix == ".py" else shell_reads(text)
        for name in names:
            found.setdefault(name, []).append(str(path.relative_to(root)))
    return found


def manifest(root):
    path = root / "internal" / "ci" / "guard_env.txt"
    verdicts = {}
    if not path.is_file():
        return verdicts
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 2:
            raise ValueError(f"{path}:{number}: expected '<VARIABLE> <verdict>', got {line!r}")
        variable, verdict = parts
        if verdict not in VERDICTS:
            raise ValueError(
                f"{path}:{number}: unknown verdict {verdict!r}; use one of {', '.join(VERDICTS)}"
            )
        verdicts[variable] = verdict
    return verdicts


def main():
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[3]
    try:
        verdicts = manifest(root)
    except ValueError as error:
        sys.stderr.write(f"check_guard_env: {error}\n")
        return 1
    found = discovered(root)
    problems = []
    for name in sorted(found):
        if name not in verdicts:
            where = ", ".join(found[name])
            problems.append(
                f"check_guard_env: {name} is read by {where} but is not classified in "
                "internal/ci/guard_env.txt; add '<VARIABLE> clear' if it is a guard opt-out, "
                "or '<VARIABLE> read' if it is a benign optional input"
            )
    for name in sorted(verdicts):
        if name not in found:
            problems.append(
                f"check_guard_env: internal/ci/guard_env.txt classifies {name}, but no guard "
                "reads it; remove the stale entry"
            )
    if problems:
        for problem in problems:
            sys.stderr.write(problem + "\n")
        return 1
    cleared = sorted(name for name, verdict in verdicts.items() if verdict == "clear")
    sys.stdout.write(
        f"check_guard_env: every guard input is classified; the canonical path clears {', '.join(cleared)}\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
