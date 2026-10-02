import json
import subprocess
import sys

DEMO_TS_PREFIX = "examples/pluto/app/demo_ts/"


def tracked():
    result = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True)
    return [line for line in result.stdout.splitlines() if line]


def context_of(path):
    parts = path.split("/")
    if len(parts) >= 3 and parts[0] == "examples":
        return "/".join(parts[:2])
    if len(parts) >= 4 and parts[0] == "internal" and parts[1] == "fixtures":
        return "/".join(parts[:3])
    raise SystemExit(f"dockerfile-matrix: cannot derive a build context for {path}")


def examples():
    entries = []
    for path in tracked():
        if not path.endswith("Dockerfile"):
            continue
        if not (path.startswith("examples/") or path.startswith("internal/fixtures/")):
            continue
        if path.startswith(DEMO_TS_PREFIX):
            continue
        entries.append({"dockerfile": path, "context": context_of(path)})
    entries.sort(key=lambda entry: entry["dockerfile"])
    return entries


def demo_ts():
    services = {
        path.split("/")[-2]
        for path in tracked()
        if path.startswith(DEMO_TS_PREFIX) and path.endswith("Dockerfile")
    }
    return sorted(services)


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else ""
    if which == "examples":
        entries = examples()
        if not entries:
            sys.exit(
                "dockerfile-matrix: git ls-files underneath examples/ and internal/fixtures/ "
                "named no Dockerfile"
            )
        seen = set()
        for entry in entries:
            if entry["dockerfile"] in seen:
                sys.exit(f"dockerfile-matrix: {entry['dockerfile']} was derived twice")
            seen.add(entry["dockerfile"])
        print(json.dumps({"include": entries}, separators=(",", ":")))
    elif which == "demo-ts":
        services = demo_ts()
        if not services:
            sys.exit(
                "dockerfile-matrix: git ls-files underneath "
                f"{DEMO_TS_PREFIX} named no Dockerfile"
            )
        print(json.dumps({"service": services}, separators=(",", ":")))
    else:
        sys.exit("usage: dockerfile_matrix.py (examples|demo-ts)")


main()
