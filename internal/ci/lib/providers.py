import os
import subprocess
from pathlib import Path


def providers(root):
    listed = os.environ.get("SOL_PROVIDERS")
    if listed:
        return listed.split()
    printer = Path(root) / "_build/default/cli/test/print_providers.exe"
    if not os.access(printer, os.X_OK):
        raise RuntimeError(f"{printer} is not built; run `dune build` first")
    out = subprocess.run([str(printer)], capture_output=True, text=True, check=True).stdout.split()
    if not out:
        raise RuntimeError("the provider printer printed nothing")
    return out
