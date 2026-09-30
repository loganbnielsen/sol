import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "internal" / "ci" / "lib"))

import cli_surface

CHECK = ROOT / "internal" / "ci" / "check_cli_reference.py"
PAGE = ROOT / "docs" / "reference" / "cli.md"
BINARY = ROOT / "_build" / "default" / "cli" / "bin" / "main.exe"

failures = []


def run_check(page):
    return subprocess.run(
        [sys.executable, str(CHECK), "--page", str(page), "--binary", str(BINARY)],
        capture_output=True,
        text=True,
    )


def expect_reject(label, page, needle):
    result = run_check(page)
    if result.returncode == 0:
        print(f"  [FAIL] the guard accepted {label}", file=sys.stderr)
        failures.append(label)
        return
    if needle not in result.stderr:
        print(
            f"  [FAIL] the guard refused {label}, but not for the reason under test: "
            f"{needle!r} is absent from its report",
            file=sys.stderr,
        )
        print(result.stderr, file=sys.stderr)
        failures.append(label)
        return
    print(f"  [OK]   {label}")


def row_for(text, command):
    for line in text.splitlines():
        if line.startswith(f"| `{command}` |"):
            return line
    raise SystemExit(f"the page has no row for {command}")


def main():
    pristine = PAGE.read_text()
    commands = sorted(cli_surface.page_command_paths(pristine))
    if not commands:
        print("  [FAIL] the page documents no command at all", file=sys.stderr)
        return 1
    victim = commands[0]

    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)

        control = directory / "control.md"
        control.write_text(pristine)
        result = run_check(control)
        if result.returncode != 0:
            print("  [FAIL] the guard refused the page it is meant to accept", file=sys.stderr)
            print(result.stderr, file=sys.stderr)
            return 1
        print("  [OK]   the unmodified page is accepted")

        dropped = directory / "dropped.md"
        dropped.write_text(
            "\n".join(line for line in pristine.splitlines() if line != row_for(pristine, victim))
        )
        expect_reject(
            f"a page that stops documenting {victim}",
            dropped,
            f"undocumented command: {victim}",
        )

        invented = directory / "invented.md"
        invented.write_text(
            pristine.rstrip("\n")
            + "\n| `sol invented-command` | — | — | — | a command the binary does not register |\n"
        )
        expect_reject(
            "a page that documents a command the binary does not register",
            invented,
            "documented command the binary does not register: sol invented-command",
        )

        flag_liar = directory / "flag-liar.md"
        liar_row = row_for(pristine, victim)
        cells = liar_row.split("|")
        cells[3] = " `--soldev-invented-flag` "
        flag_liar.write_text(pristine.replace(liar_row, "|".join(cells)))
        expect_reject(
            f"a page that gives {victim} a flag it does not have",
            flag_liar,
            "--soldev-invented-flag",
        )

    if failures:
        print(
            f"test_cli_reference_check: {len(failures)} mutation(s) went uncaught",
            file=sys.stderr,
        )
        return 1
    print(
        "test_cli_reference_check: the guard refuses an undocumented command, a command the "
        "binary does not register, and a flag the command does not have"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
