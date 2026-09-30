import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "internal" / "ci" / "lib"))

import cli_surface


def main():
    parser = argparse.ArgumentParser(
        description="Fail when docs/reference/cli.md no longer matches the CLI's own help."
    )
    parser.add_argument("--binary", default=str(ROOT / "_build" / "default" / "cli" / "bin" / "main.exe"))
    parser.add_argument("--page", default=str(ROOT / "docs" / "reference" / "cli.md"))
    args = parser.parse_args()

    page = Path(args.page)
    if not page.exists():
        print(f"check_cli_reference: {page} does not exist", file=sys.stderr)
        return 1
    current = page.read_text()
    rendered = cli_surface.rendered_page(current, cli_surface.registered(args.binary))

    drift = cli_surface.surface_drift(current, cli_surface.registered(args.binary))

    if current == rendered and not drift:
        commands = len(cli_surface.page_command_paths(rendered))
        print(
            f"check_cli_reference: docs/reference/cli.md documents all {commands} "
            "registered commands, with the flags the binary reports"
        )
        return 0

    print(
        "check_cli_reference: docs/reference/cli.md is out of date against the CLI's own "
        "help. Regenerate it with: "
        "python3 internal/tooling/scripts/render-cli-reference.py",
        file=sys.stderr,
    )
    for line in drift:
        print(f"  {line}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
