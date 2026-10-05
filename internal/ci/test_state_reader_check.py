#!/usr/bin/env python3
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "internal/ci/check_state_reader.py"
COPIED = [
    "cli/lib/cloud/sol_cli_terraform.mli",
    "cli/lib/cloud/sol_cli_terraform.ml",
    "cli/bin/cmd_uninstall.ml",
]


def scratch():
    tmp = Path(tempfile.mkdtemp())
    for relative in COPIED:
        source = ROOT / relative
        target = tmp / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(source, target)
    return tmp


def run(tmp):
    return subprocess.run(
        [sys.executable, str(GUARD), str(tmp)], capture_output=True, text=True
    )


def mutate(tmp, relative, old, new):
    path = tmp / relative
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"mutation anchor not found in {relative}: {old!r}")
    path.write_text(text.replace(old, new, 1))


def main():
    failures = []
    cases = []

    real = scratch()
    result = run(real)
    if result.returncode != 0:
        failures.append("the real tree was rejected:\n" + result.stderr)

    tmp = scratch()
    mutate(
        tmp,
        "cli/lib/cloud/sol_cli_terraform.mli",
        "val state_addresses",
        'val state_list\n  :  ?env:(string * string) list\n  -> chdir:string\n  -> unit\n'
        '  -> (Sol_cli_process.output, Sol_cli_process.error) result\n\nval state_addresses',
    )
    cases.append(("the raw listing exported again", tmp))

    tmp = scratch()
    mutate(
        tmp,
        "cli/bin/cmd_uninstall.ml",
        "Sol_cli_terraform.state_addresses ~chdir ()",
        "Sol_cli_terraform.state_list ~chdir ()",
    )
    cases.append(("a module reading the raw listing", tmp))

    for label, tmp in cases:
        result = run(tmp)
        if result.returncode == 0:
            failures.append(f"the guard accepted {label}")
        else:
            print(f"  rejected: {label}")

    shutil.rmtree(real, ignore_errors=True)
    shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        for failure in failures:
            print(f"test_state_reader_check: {failure}", file=sys.stderr)
        return 1
    print(
        "test_state_reader_check: the guard accepts the real tree and rejects the raw listing "
        "exported again, and a module reading it"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
