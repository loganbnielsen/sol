#!/usr/bin/env bash
# Installs Sol git hooks into .git/hooks/ as symlinks.
# Re-running is safe — existing symlinks are updated, existing non-symlink hooks
# are backed up first.
#
# Usage: bash platform/local/scripts/install-hooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOOKS_SRC="$REPO_ROOT/devtools/hooks"
HOOKS_DEST="$REPO_ROOT/.git/hooks"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

install_hook() {
  local name=$1
  local src="$HOOKS_SRC/$name"
  local dest="$HOOKS_DEST/$name"

  chmod +x "$src"

  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    echo -e "${YELLOW}!${NC} $name already exists (not a symlink) — backing up to ${name}.bak"
    mv "$dest" "${dest}.bak"
  fi

  ln -sf "$src" "$dest"
  echo -e "${GREEN}✓${NC} $name"
}

echo ""
echo "Installing Sol git hooks..."
echo ""

for hook in "$HOOKS_SRC"/*; do
  install_hook "$(basename "$hook")"
done

echo ""
echo "Configuring git merge drivers..."
git -C "$REPO_ROOT" config merge.ours.name "Keep ours on conflict"
git -C "$REPO_ROOT" config merge.ours.driver true
echo -e "${GREEN}✓${NC} merge.ours (perf_baseline.json always keeps main's version)"

echo ""
echo "Done. To skip all Sol hooks once: SOL_SKIP_HOOKS=1 git commit ..."
echo ""
