import json
import os
import re
import subprocess
import sys
import tokenize

QUOTED = re.compile(r"\{([a-z_]*)\|")
OCAML_CHAR = re.compile(r"'(\\([\\'\"ntbr ]|[0-9]{3}|x[0-9a-fA-F]{2}|o[0-7]{3})|[^\\\n])'")
SHELL_DIRECTIVE = re.compile(r"#\s*shellcheck\b")
TS_DIRECTIVE = re.compile(r"(///\s*<reference|//\s*@ts-|/[/*]\s*eslint-(disable|enable))")


def line_of(src, i):
    return src.count("\n", 0, i) + 1


def ocaml(src):
    i, n = 0, len(src)
    while i < n:
        if src.startswith("(*", i) and not src.startswith("(*)", i):
            return [line_of(src, i)]
        c = src[i]
        if c == '"':
            i += 1
            while i < n and src[i] != '"':
                i += 2 if src[i] == "\\" else 1
            i += 1
        elif c == "{" and QUOTED.match(src, i):
            m = QUOTED.match(src, i)
            end = src.find("|" + m.group(1) + "}", m.end())
            i = n if end < 0 else end + len(m.group(1)) + 2
        elif c == "'" and OCAML_CHAR.match(src, i):
            i = OCAML_CHAR.match(src, i).end()
        else:
            i += 1
    return []


def shell_comments(path):
    try:
        with open(path, encoding="utf-8") as f:
            out = subprocess.run(
                ["shfmt", "--to-json", "-ln", "bash"],
                stdin=f, capture_output=True, text=True, check=True,
            ).stdout
    except FileNotFoundError:
        sys.exit("check_no_comments: shfmt is not installed; the shell check needs its parser")
    except subprocess.CalledProcessError as e:
        sys.exit(f"check_no_comments: shfmt could not parse {path}: {e.stderr.strip()}")
    found = set()

    def walk(node):
        if isinstance(node, dict):
            if "Hash" in node:
                line, text = node["Hash"]["Line"], "#" + node.get("Text", "")
                if not (line == 1 and text.startswith("#!")) and not SHELL_DIRECTIVE.match(text):
                    found.add(line)
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(json.loads(out))
    return sorted(found)


def terraform(src):
    found = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            i = hcl_string(src, i + 1)
        elif src.startswith("<<", i) and re.match(r"<<-?[A-Za-z_]", src[i:]):
            m = re.match(r"<<-?([A-Za-z_][A-Za-z0-9_]*)[^\n]*\n", src[i:])
            if not m:
                i += 2
                continue
            end = re.compile(r"^[ \t]*" + m.group(1) + r"[ \t]*$", re.M).search(src, i + m.end())
            i = n if end is None else end.end()
        elif c == "#" or src.startswith("//", i):
            found.append(line_of(src, i))
            nl = src.find("\n", i)
            i = n if nl < 0 else nl
        elif src.startswith("/*", i):
            found.append(line_of(src, i))
            end = src.find("*/", i + 2)
            i = n if end < 0 else end + 2
        else:
            i += 1
    return found


def hcl_string(src, i):
    n = len(src)
    while i < n:
        c = src[i]
        if c == "\\":
            i += 2
        elif c == '"':
            return i + 1
        elif src.startswith("${", i) or src.startswith("%{", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if src[i] == '"':
                    i = hcl_string(src, i + 1)
                    continue
                depth += {"{": 1, "}": -1}.get(src[i], 0)
                i += 1
        else:
            i += 1
    return n


def typescript(src):
    found = []
    i, n = 0, len(src)
    prev = ""
    while i < n:
        c = src[i]
        if c in "'\"":
            i += 1
            while i < n and src[i] != c:
                i += 2 if src[i] == "\\" else 1
            i += 1
            prev = "x"
        elif c == "`":
            i = ts_template(src, i + 1)
            prev = "x"
        elif src.startswith("//", i) or src.startswith("/*", i):
            end = src.find("\n", i) if src[i + 1] == "/" else src.find("*/", i) + 2
            end = n if end < i else end
            if not TS_DIRECTIVE.match(src[i:end]):
                found.append(line_of(src, i))
            i = end
        elif c == "/" and prev in "(,=:[!&|?{};+-*%<>~^" + "":
            i += 1
            in_class = False
            while i < n and (src[i] != "/" or in_class):
                if src[i] == "\\":
                    i += 1
                elif src[i] == "[":
                    in_class = True
                elif src[i] == "]":
                    in_class = False
                i += 1
            i += 1
            prev = "x"
        else:
            if not c.isspace():
                prev = c if not (c.isalnum() or c in "_$)]") else "x"
            i += 1
    return found


def ts_template(src, i):
    n = len(src)
    while i < n:
        if src[i] == "\\":
            i += 2
        elif src[i] == "`":
            return i + 1
        elif src.startswith("${", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if src[i] == "`":
                    i = ts_template(src, i + 1)
                    continue
                if src[i] in "'\"":
                    q, i = src[i], i + 1
                    while i < n and src[i] != q:
                        i += 2 if src[i] == "\\" else 1
                depth += {"{": 1, "}": -1}.get(src[i], 0)
                i += 1
        else:
            i += 1
    return n


PYTHON_DIRECTIVE = re.compile(r"#\s*(noqa\b|type:|pragma:|-\*-\s*coding)")


def python(src):
    found = []
    lines = iter(src.splitlines(keepends=True))
    for token in tokenize.generate_tokens(lambda: next(lines, "")):
        if token.type != tokenize.COMMENT:
            continue
        line = token.start[0]
        if line == 1 and token.string.startswith("#!"):
            continue
        if PYTHON_DIRECTIVE.match(token.string):
            continue
        found.append(line)
    return found


def language(path):
    name = os.path.basename(path)
    if path.endswith((".ml", ".mli")):
        return ocaml
    if path.endswith((".sh", ".bash")) or name in ("pre-commit", "post-commit"):
        return "shell"
    if path.endswith((".tf", ".tfvars")):
        return terraform
    if path.endswith(".ts"):
        return typescript
    if path.endswith(".py"):
        return python
    return None


def main():
    root = sys.argv[1]
    paths = [p for p in sys.stdin.read().split("\0") if p]
    found, checked = [], 0
    for path in paths:
        detect = language(path)
        if detect is None:
            continue
        checked += 1
        full = os.path.join(root, path)
        if detect == "shell":
            lines = shell_comments(full)
        else:
            with open(full, encoding="utf-8") as f:
                lines = detect(f.read())
        found += [f"{path}:{line}" for line in lines]
    for hit in found:
        print(f"check_no_comments: {hit}", file=sys.stderr)
    if found:
        print(
            "check_no_comments: name things so the code explains itself; an invariant "
            "belongs in a type, a shared definition or a test, not a comment",
            file=sys.stderr,
        )
        sys.exit(1)
    print(f"check_no_comments: {checked} file(s) checked; none has a comment")


main()
