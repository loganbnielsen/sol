import os
import sys

if len(sys.argv) > 2 and sys.argv[1] == "--root":
    os.chdir(sys.argv[2])
else:
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

import re, sys, pathlib
MANIFEST = [
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Auth`", ["framework/ocaml/sol-svc/lib/auth.mli"]),
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Peer`", ["framework/ocaml/sol-svc/lib/peer.mli"]),
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Route`", ["framework/ocaml/sol-svc/lib/route.mli"]),
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Request`", ["framework/ocaml/sol-svc/lib/request.mli"]),
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Response`", ["framework/ocaml/sol-svc/lib/response.mli"]),
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Service`", ["framework/ocaml/sol-svc/lib/service.mli"]),
    ("framework/ocaml/kafka-eio-service/kafka-eio-service.md", "## Configuration", ["framework/ocaml/kafka-eio-service/lib/kafka_service.mli"]),
    ("framework/ocaml/kafka-eio-service/kafka-eio-service.md", "## Public API", ["framework/ocaml/kafka-eio-service/lib/kafka_service.mli"]),
]

KEYWORDS = ("val", "type", "exception", "external", "module")


def strip_comments(s):
    prev = None
    while prev != s:
        prev = s
        s = re.sub(r"\(\*.*?\*\)", " ", s, flags=re.S)
    return s


def norm(text):
    return re.sub(r"\s+", " ", strip_comments(text)).strip()


def declarations(text):
    """(keyword, name, normalised declaration text) for each declaration."""
    chunks, cur = [], None
    for raw in text.split("\n"):
        line = raw.strip()
        if not line:
            continue
        first = line.split()[0] if line.split() else ""
        if first in KEYWORDS and not line.startswith("|"):
            if cur:
                chunks.append(cur)
            cur = [line]
        elif cur is not None:
            if line == "end":
                chunks.append(cur)
                cur = None
                continue
            cur.append(line)
    if cur:
        chunks.append(cur)
    for chunk in chunks:
        joined = norm(" ".join(chunk))
        keyword = chunk[0].split()[0]
        rest = joined[len(keyword):].strip()
        name = re.split(r"[^A-Za-z0-9_']", rest, 1)[0] if rest else ""
        yield keyword, name, joined


def spec_declarations(md_text, heading):
    """Declarations inside ```ocaml blocks of one section (up to the next '## ')."""
    lines = md_text.split("\n")
    try:
        start = next(i for i, l in enumerate(lines) if l.strip() == heading)
    except StopIteration:
        print(f"✗ checker manifest names a section that does not exist: {heading}", file=sys.stderr)
        sys.exit(2)
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i].startswith("## "):
            end = i
            break
    section = "\n".join(lines[start:end])
    out = []
    for block in re.findall(r"^```ocaml\n(.*?)^```", section, flags=re.S | re.M):
        for keyword, name, joined in declarations(block):
            if keyword == "module":
                continue
            out.append((keyword, name, joined))
    return out


def mli_declarations(paths):
    have = {}
    for path in paths:
        text = pathlib.Path(path).read_text()
        for keyword, name, joined in declarations(text):
            have.setdefault((keyword, name), []).append(joined)
    return have


problems = 0
for doc, heading, mlis in MANIFEST:
    have = mli_declarations(mlis)
    for keyword, name, joined in spec_declarations(pathlib.Path(doc).read_text(), heading):
        key = (keyword, name)
        if key not in have:
            print(f"✗ {doc}: {heading} documents `{name}`, which {', '.join(mlis)} does not declare")
            print(f"    {joined[:160]}")
            problems += 1
        elif joined not in have[key]:
            print(f"✗ {doc}: {heading} shows a stale signature for `{name}`")
            print(f"    doc: {joined[:160]}")
            print(f"    mli: {have[key][0][:160]}")
            problems += 1

if problems:
    print("")
    print(f"✗ {problems} stale framework spec signature(s). Update the doc to match the .mli.")
    sys.exit(1)
print("framework doc signatures: all spec declarations match their .mli.")
