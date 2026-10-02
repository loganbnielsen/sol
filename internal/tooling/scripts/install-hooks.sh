#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GREEN='\033[0;32m'; NC='\033[0m'

chmod +x "$REPO_ROOT"/internal/tooling/hooks/*
git -C "$REPO_ROOT" config core.hooksPath internal/tooling/hooks

echo ""
echo -e "${GREEN}✓${NC} core.hooksPath = internal/tooling/hooks (every worktree runs its own checkout's hooks)"
echo ""
echo "Configuring git merge drivers..."
git -C "$REPO_ROOT" config merge.ours.name "Keep ours on conflict"
git -C "$REPO_ROOT" config merge.ours.driver true
echo -e "${GREEN}✓${NC} merge.ours (perf_baseline.json always keeps main's version)"

echo ""
echo "Done. To skip all Sol hooks once: SOL_SKIP_HOOKS=1 git commit|push ..."
echo ""
