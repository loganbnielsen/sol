import os
import subprocess
from pathlib import Path


def _rows(text):
    rows = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t")
        name = parts[0].strip()
        status = parts[1].strip() if len(parts) > 1 else ""
        rows.append((name, status))
    return rows


def provider_rows(root):
    listed = os.environ.get("SOL_PROVIDERS")
    if listed:
        return _rows(listed)
    printer = Path(root) / "_build/default/cli/test/print_providers.exe"
    if not os.access(printer, os.X_OK):
        raise RuntimeError(f"{printer} is not built; run `dune build` first")
    out = subprocess.run([str(printer)], capture_output=True, text=True, check=True).stdout
    rows = _rows(out)
    if not rows:
        raise RuntimeError("the provider printer printed nothing")
    return rows


def providers(root):
    return [name for name, _ in provider_rows(root)]
