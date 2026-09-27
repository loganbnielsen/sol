#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

git -C "$root" ls-files -z -- '*.ml' '*.mli' | ROOT="$root" python3 -c '
import os, re, sys

QUOTED = re.compile(r"\{([a-z_]*)\|")
CHAR = re.compile(r"'"'"'(\\([\\'"'"'\"ntbr ]|[0-9]{3}|x[0-9a-fA-F]{2}|o[0-7]{3})|[^\\\n])'"'"'")


def first_comment(s):
    i, n = 0, len(s)
    while i < n:
        if s.startswith("(*", i) and not s.startswith("(*)", i):
            return s.count("\n", 0, i) + 1
        c = s[i]
        if c == "\"":
            i += 1
            while i < n and s[i] != "\"":
                i += 2 if s[i] == "\\" else 1
            i += 1
        elif c == "{" and QUOTED.match(s, i):
            m = QUOTED.match(s, i)
            end = s.find("|" + m.group(1) + "}", m.end())
            i = n if end < 0 else end + len(m.group(1)) + 2
        elif c == "'"'"'" and CHAR.match(s, i):
            i = CHAR.match(s, i).end()
        else:
            i += 1
    return None


root = os.environ["ROOT"]
paths = [p for p in sys.stdin.read().split("\0") if p]
found = []
for path in paths:
    with open(os.path.join(root, path), encoding="utf-8") as f:
        line = first_comment(f.read())
    if line:
        found.append(f"{path}:{line}")
for hit in found:
    print(f"check_no_comments: {hit}", file=sys.stderr)
if found:
    print("check_no_comments: name things so the code explains itself; an invariant belongs in a type, a shared definition or a test, not a comment", file=sys.stderr)
    sys.exit(1)
print(f"check_no_comments: {len(paths)} OCaml file(s) checked; none has a comment")
'
