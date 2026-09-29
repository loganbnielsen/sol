import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())

ticket = """---
id: {id}
type: bug
severity: medium
title: {title}
source: test
---

{title}

**Depends on:** None.
"""

gh_stub = """#!/usr/bin/env python3
import os
from pathlib import Path
import sys

root = Path(os.environ["GH_TEST_ROOT"])
with open(root / "gh-calls", "a") as calls:
    calls.write(" ".join(sys.argv[1:]) + "\\n")
if (root / "gh-mode").read_text().strip() == "fail":
    sys.stderr.write("audit-authentication-failed\\n")
    sys.exit(1)
sys.stdout.write((root / "gh-payload").read_text())
"""

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    repo = root / "repo"
    tools = root / "tools"
    ready = repo / "internal" / "pipeline" / "tickets" / "READY_FOR_ENGINEERING"
    ready.mkdir(parents=True)
    tools.mkdir()
    (ready / "BUG-101.md").write_text(ticket.format(id="BUG-101", title="First ticket"))
    (ready / "BUG-102.md").write_text(ticket.format(id="BUG-102", title="Second ticket"))
    subprocess.check_call(["git", "init", "-b", "main", str(repo)], stdout=subprocess.DEVNULL)

    gh = tools / "gh"
    gh.write_text(gh_stub)
    gh.chmod(0o755)
    calls = root / "gh-calls"
    env = dict(
        os.environ,
        PATH=str(tools) + os.pathsep + os.environ["PATH"],
        GH_TEST_ROOT=str(root),
    )

    def set_gh(ok, payload="[]"):
        (root / "gh-mode").write_text("ok" if ok else "fail")
        (root / "gh-payload").write_text(payload)
        if calls.exists():
            calls.unlink()

    def invocations():
        return len(calls.read_text().splitlines()) if calls.exists() else 0

    def run(*args):
        return subprocess.run(
            [binary, *args], cwd=repo, env=env, capture_output=True, text=True
        )

    set_gh(False)
    result = run("pipeline", "ls")
    assert result.returncode != 0, result.stdout + result.stderr
    assert "audit-authentication-failed" in result.stderr, result.stderr

    set_gh(False)
    result = run("pipeline", "merge")
    assert result.returncode != 0, result.stdout + result.stderr
    assert "audit-authentication-failed" in result.stderr, result.stderr
    assert "No open PRs to merge" not in result.stdout, result.stdout

    set_gh(True, "[]")
    result = run("pipeline", "ls")
    assert result.returncode == 0, result.stdout + result.stderr
    assert invocations() == 1, (invocations(), result.stdout)
    assert "BUG-101" in result.stdout and "BUG-102" in result.stdout, result.stdout
    assert "PR #" not in result.stdout, result.stdout

    set_gh(
        True,
        json.dumps(
            [
                {
                    "number": 77,
                    "url": "https://example.test/pull/77",
                    "headRefName": "BUG-101/first",
                    "headRefOid": "a" * 40,
                    "isDraft": False,
                }
            ]
        ),
    )
    result = run("pipeline", "ls")
    assert result.returncode == 0, result.stdout + result.stderr
    assert invocations() == 1, (invocations(), result.stdout)
    first = [line for line in result.stdout.splitlines() if "BUG-101" in line]
    second = [line for line in result.stdout.splitlines() if "BUG-102" in line]
    assert first and "PR #77" in first[0], result.stdout
    assert second and "PR #" not in second[0], result.stdout

print("soldev PR inventory checks passed")
