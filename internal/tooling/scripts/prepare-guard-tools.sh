#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
requirements="$root/internal/ci/requirements.txt"

python_deps_present() {
  python3 -c 'import hcl2, yaml, lark, regex, tomli' 2>/dev/null
}

install_python_deps() {
  if python_deps_present; then
    echo "guard Python dependencies: already importable"
    return 0
  fi
  if python3 -m pip install --user --no-deps -r "$requirements" >/dev/null 2>&1; then
    echo "guard Python dependencies: installed into the user site"
  else
    echo "guard Python dependencies: pip refused a user install (an externally managed"
    echo "environment, PEP 668); installing the same pinned set into the user site instead"
    python3 -m pip install --user --break-system-packages --no-deps -r "$requirements"
  fi
  python_deps_present || {
    echo "prepare-guard-tools: the guard Python dependencies are still not importable" >&2
    return 1
  }
}

install_python_deps
