import re
import sys
from dataclasses import dataclass
from pathlib import Path

try:
    import hcl2
except ImportError:
    sys.exit(
        "python-hcl2 is not installed: pip install -r internal/ci/requirements.txt"
    )

_OPTIONS = hcl2.SerializationOptions(with_comments=False)


def unquote(value):
    if isinstance(value, str) and len(value) >= 2 and value[0] == value[-1] == '"':
        return value[1:-1]
    return value


def is_string_literal(value):
    return isinstance(value, str) and len(value) >= 2 and value[0] == value[-1] == '"'


def variable_reference(value):
    match = re.fullmatch(r"\$\{var\.([A-Za-z0-9_]+)\}", value) if isinstance(value, str) else None
    return match.group(1) if match else None


def blocks(body, name):
    value = body.get(name, [])
    return value if isinstance(value, list) else [value]


@dataclass
class Resource:
    kind: str
    type: str
    name: str
    body: dict
    path: Path
    line: int

    @property
    def address(self):
        prefix = "data." if self.kind == "data" else ""
        return f"{prefix}{self.type}.{self.name}"

    @property
    def where(self):
        return f"{self.path}:{self.line}"


def _header_line(text, kind, type_, name):
    pattern = rf'^\s*{kind}\s+"{re.escape(type_)}"\s+"{re.escape(name)}"'
    match = re.search(pattern, text, re.M)
    return text.count("\n", 0, match.start()) + 1 if match else 0


def load(path):
    path = Path(path)
    with open(path, encoding="utf-8") as f:
        return hcl2.load(f, serialization_options=_OPTIONS)


def resources(path, kinds=("resource", "data")):
    path = Path(path)
    doc = load(path)
    text = path.read_text(encoding="utf-8")
    found = []
    for kind in kinds:
        for entry in doc.get(kind, []):
            for type_, named in entry.items():
                for name, body in named.items():
                    t, n = unquote(type_), unquote(name)
                    found.append(Resource(kind, t, n, body, path, _header_line(text, kind, t, n)))
    return found


def modules(path):
    path = Path(path)
    doc = load(path)
    text = path.read_text(encoding="utf-8")
    return [
        Resource("module", "module", unquote(name), body, path, _header_line_module(text, unquote(name)))
        for entry in doc.get("module", [])
        for name, body in entry.items()
    ]


def _header_line_module(text, name):
    match = re.search(rf'^\s*module\s+"{re.escape(name)}"', text, re.M)
    return text.count("\n", 0, match.start()) + 1 if match else 0


def variables(path):
    doc = load(path)
    return {
        unquote(name): body
        for entry in doc.get("variable", [])
        for name, body in entry.items()
    }


def attributes(node, key):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == key:
                yield v
            yield from attributes(v, key)
    elif isinstance(node, list):
        for v in node:
            yield from attributes(v, key)
