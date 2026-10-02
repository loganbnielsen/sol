"""Fail when a CLI test module is not reachable by any test runner.

A module under the scanned root must belong to one of three places: a
directory whose dune enables (inline_tests), a directory holding a (library)
stanza (a helper library linked into tests), or the explicit executable test
set named by (tests (names ...)) / (test (name ...)). A module in none of them
is never compiled or never run, which is how a test disappears silently.
"""

import os
import sys


def parse_sexps(text):
    stack = [[]]
    token = []
    in_string = False
    escaped = False
    in_comment = False
    for char in text:
        if in_comment:
            if char == "\n":
                in_comment = False
            continue
        if in_string:
            if escaped:
                token.append(char)
                escaped = False
            elif char == "\\":
                token.append(char)
                escaped = True
            elif char == '"':
                stack[-1].append("".join(token))
                token = []
                in_string = False
            else:
                token.append(char)
            continue
        if char == '"':
            if token:
                stack[-1].append("".join(token))
                token = []
            in_string = True
        elif char == ";":
            if token:
                stack[-1].append("".join(token))
                token = []
            in_comment = True
        elif char == "(":
            if token:
                stack[-1].append("".join(token))
                token = []
            stack.append([])
        elif char == ")":
            if token:
                stack[-1].append("".join(token))
                token = []
            if len(stack) < 2:
                raise ValueError("unbalanced parentheses")
            finished = stack.pop()
            stack[-1].append(finished)
        elif char.isspace():
            if token:
                stack[-1].append("".join(token))
                token = []
        else:
            token.append(char)
    if token:
        stack[-1].append("".join(token))
    if len(stack) != 1:
        raise ValueError("unbalanced parentheses")
    return stack[0]


def field(stanza, name):
    if not isinstance(stanza, list) or not stanza or stanza[0] != name:
        return None
    for item in stanza[1:]:
        if isinstance(item, list) and item and item[0] == name:
            return item[1:]
    return None


def fields(stanza, name):
    found = []
    if not isinstance(stanza, list) or not stanza:
        return found
    for item in stanza[1:]:
        if isinstance(item, list) and item and item[0] == name:
            found.append(item[1:])
    return found


def dune_facts(path):
    with open(path, encoding="utf-8") as handle:
        sexps = parse_sexps(handle.read())
    inline = False
    library = False
    names = set()
    for stanza in sexps:
        if not isinstance(stanza, list) or not stanza:
            continue
        head = stanza[0]
        if head == "library":
            library = True
            inline = inline or field(stanza, "inline_tests") is not None
        elif head in ("tests", "executables"):
            for entry in fields(stanza, "names"):
                names.update(
                    item
                    for item in entry
                    if isinstance(item, str) and item != ":standard"
                )
        elif head in ("test", "executable"):
            for entry in fields(stanza, "name"):
                names.update(
                    item
                    for item in entry
                    if isinstance(item, str) and item != ":standard"
                )
    return inline, library, names


def scan(root):
    problems = []
    for directory, _, files in os.walk(root):
        if "dune" in files:
            inline, library, names = dune_facts(os.path.join(directory, "dune"))
        else:
            inline, library, names = False, False, set()
        for name in sorted(files):
            if not name.endswith(".ml"):
                continue
            stem = name[: -len(".ml")]
            if inline:
                continue
            if stem in names:
                continue
            if library:
                continue
            problems.append(os.path.join(directory, name))
    return sorted(problems)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "cli/test"
    problems = scan(root)
    if problems:
        for path in problems:
            sys.stderr.write(
                "check_test_reachability: %s is neither in an (inline_tests) library nor "
                "named by a (tests (names ...)) executable stanza, so no runner would "
                "compile or run it\n" % path
            )
        sys.stderr.write(
            "check_test_reachability: move it into the inline-test library, or add it to "
            "the legacy executable set while the migration is in progress\n"
        )
        return 1
    sys.stdout.write("check_test_reachability: every module under %s is reachable\n" % root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
