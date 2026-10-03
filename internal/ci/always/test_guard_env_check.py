"""Pin the guard-input classifier's contract: an unclassified input fails."""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

GUARD = Path(__file__).resolve().parent / "check_guard_env.py"
FAILURES = []


def ok(message):
    sys.stdout.write(f"  [OK]   {message}\n")


def bad(message):
    sys.stdout.write(f"  [FAIL] {message}\n")
    FAILURES.append(message)


def build(root, members, manifest):
    shutil.rmtree(root / "internal", ignore_errors=True)
    ci = root / "internal" / "ci"
    (ci / "always").mkdir(parents=True, exist_ok=True)
    for name, text in members.items():
        (ci / name).write_text(text, encoding="utf-8")
    if manifest is not None:
        (ci / "guard_env.txt").write_text(manifest, encoding="utf-8")


def run(root):
    result = subprocess.run(
        [sys.executable, str(GUARD), str(root)],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.returncode, result.stdout + result.stderr


def expect(name, root, returncode, needle):
    code, output = run(root)
    if code != returncode:
        bad(f"{name}: expected exit {returncode}, got {code}\n{output}")
        return
    if needle not in output:
        bad(f"{name}: output does not name {needle!r}\n{output}")
        return
    ok(name)


with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)

    build(root, {"check_fixture.sh": 'opt="${SOME_OPTOUT:-0}"\n[ "$opt" = 1 ]\n'}, None)
    expect("an unclassified opt-out fails and is named", root, 1, "SOME_OPTOUT")

    build(root, {"check_fixture.sh": 'opt="${SOME_OPTOUT:-0}"\n[ "$opt" = 1 ]\n'}, "SOME_OPTOUT clear\n")
    expect("a classified opt-out passes and is reported as cleared", root, 0, "clears SOME_OPTOUT")

    build(root, {"check_fixture.sh": 'opt="${SOME_OPTOUT:-0}"\n[ "$opt" = 1 ]\n'}, "SOME_OPTOUT read\n")
    expect("a classified benign input passes without being cleared", root, 0, "every guard input is classified")

    build(root, {"check_fixture.sh": 'opt="${SOME_OPTOUT:-0}"\n[ "$opt" = 1 ]\n'}, "GONE read\n")
    expect("a stale classification fails", root, 1, "remove the stale entry")

    build(root, {"check_fixture.sh": 'opt="${SOME_OPTOUT:-0}"\n[ "$opt" = 1 ]\n'}, "SOME_OPTOUT maybe\n")
    expect("an unknown verdict fails", root, 1, "unknown verdict")

    build(root, {"check_fixture.sh": 'opt="${SOME_OPTOUT:-0}"\n[ "$opt" = 1 ]\n'}, "SOME_OPTOUT\n")
    expect("a malformed line fails", root, 1, "expected '<VARIABLE> <verdict>'")

    build(
        root,
        {
            "check_local.sh": 'BRANCH="$(git rev-parse --abbrev-ref HEAD)"\nopt="${BRANCH:-none}"\n',
            "check_remote.py": 'import os\nopt = os.environ.get("PY_OPTOUT", "0")\n',
        },
        "PY_OPTOUT clear\n",
    )
    expect("a computed shell local is not an input, a python read is", root, 0, "clears PY_OPTOUT")

    build(
        root,
        {"check_fixture.sh": 'opt="${SOME_OPTOUT:-0}"\n[ "$opt" = 1 ]\n'},
        "SOME_OPTOUT clear\nSOME_OPTOUT read\n",
    )
    expect("a duplicate classification is last-wins", root, 0, "every guard input is classified")

if FAILURES:
    sys.stdout.write(f"test_guard_env_check: {len(FAILURES)} expectation(s) FAILED\n")
    sys.exit(1)
sys.stdout.write("test_guard_env_check: every case behaved\n")
