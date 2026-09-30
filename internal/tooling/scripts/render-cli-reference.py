import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "internal" / "ci" / "lib"))

import cli_surface


def main():
    parser = argparse.ArgumentParser(
        description="Render or verify docs/reference/cli.md against the CLI's own help."
    )
    parser.add_argument("--binary", default=str(ROOT / "_build" / "default" / "cli" / "bin" / "main.exe"))
    parser.add_argument("--page", default=str(ROOT / "docs" / "reference" / "cli.md"))
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    page = Path(args.page)
    if not page.exists():
        print(f"render-cli-reference: {page} does not exist", file=sys.stderr)
        return 1
    current = page.read_text()
    rendered = cli_surface.rendered_page(current, cli_surface.registered(args.binary))

    if args.check:
        if current == rendered:
            pass
        if current == rendered and not cli_surface.surface_drift(current, cli_surface.registered(args.binary)):
            print("render-cli-reference: the page matches the registered command surface")
            return 0
        print(
            "render-cli-reference: the page is stale; run "
            "python3 internal/tooling/scripts/render-cli-reference.py",
            file=sys.stderr,
        )
        for line in cli_surface.surface_drift(current, cli_surface.registered(args.binary)):
            print(f"  {line}", file=sys.stderr)
        return 1

    if current != rendered:
        page.write_text(rendered)
        print(f"render-cli-reference: rewrote {page}")
    else:
        print("render-cli-reference: already current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
