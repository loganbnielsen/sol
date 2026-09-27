#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
requirements="$root/internal/ci/requirements.txt"
bindir="${HOME}/.local/bin"
shfmt_version="v3.12.0"

python_deps_present() {
  python3 -c 'import hcl2, yaml, lark, regex' 2>/dev/null
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

install_shfmt() {
  if [ -x "$bindir/shfmt" ] && "$bindir/shfmt" --version 2>/dev/null | grep -qx "$shfmt_version"; then
    echo "shfmt $shfmt_version: already installed"
    return 0
  fi
  mkdir -p "$bindir"
  curl -fsSL -o "$bindir/shfmt" \
    "https://github.com/mvdan/sh/releases/download/${shfmt_version}/shfmt_${shfmt_version}_linux_amd64"
  chmod +x "$bindir/shfmt"
  "$bindir/shfmt" --version
}

install_python_deps
install_shfmt

case ":${PATH}:" in
  *":${bindir}:"*) ;;
  *) echo "prepare-guard-tools: add ${bindir} to PATH for check_no_comments.sh to find shfmt" ;;
esac
