#!/usr/bin/env bash
# Every public signature shown in a framework package's spec must still exist in
# that package's .mli (DOCS-017).
#
# The specs (framework/ocaml/<pkg>/<pkg>.md) are where a reader learns the API, and
# they are hand-written copies of declarations that only the .mli can be right
# about. They had drifted: `config_of_env` had lost its `result`,
# `Response.not_implemented` was documented but not public, `Request.t` omitted
# `trace_ctx`, `Service.run` had the wrong env shape and no `?stop`, and old flat
# Kafka module names remained. Nothing made a stale block fail, so nothing noticed.
#
# What this checks, and deliberately does not:
#
#   - Declaration *text*, not English. Comments are stripped and whitespace is
#     collapsed, so a block may carry richer prose than the .mli; it must not
#     carry a different signature.
#   - Declarations shown must exist in the mapped .mli. A spec that shows a subset
#     is fine — it is a spec, not a transcription. A spec that shows a declaration
#     the .mli no longer has, or a different signature for one it does, is not.
#   - Sections are mapped to modules explicitly below, so an example that happens to
#     contain a `type` (the kafka doc's message-contract sample) is not mistaken for
#     a framework signature, and `type t` is not compared against the wrong module.
#
# Exit: 0 clean, 1 drift found, 2 the checker could not run.
set -uo pipefail

# The repository root, or a scratch copy of it for the mutation test.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ "${1:-}" = "--root" ]; then
  ROOT="${2:?--root needs a directory}"
fi
cd "$ROOT" || exit 2

python3 - <<'PY'
import re, sys, pathlib

# (doc, section heading, mli files the section specifies)
MANIFEST = [
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Sol_svc.Auth`", ["framework/ocaml/sol-svc/lib/auth.mli"]),
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Peer`", ["framework/ocaml/sol-svc/lib/peer.mli"]),
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Sol_svc.Route`", ["framework/ocaml/sol-svc/lib/route.mli"]),
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Sol_svc.Request`", ["framework/ocaml/sol-svc/lib/request.mli"]),
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Sol_svc.Response`", ["framework/ocaml/sol-svc/lib/response.mli"]),
    ("framework/ocaml/sol-svc/sol-svc.md", "## Module: `Sol_svc.Service`", ["framework/ocaml/sol-svc/lib/service.mli"]),
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
PY
