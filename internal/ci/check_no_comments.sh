#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

git -C "$root" ls-files -z -- '*.ml' '*.mli' '*.sh' '*.bash' '*.tf' '*.tfvars' '*.ts' \
  'internal/tooling/hooks/pre-commit' 'internal/tooling/hooks/post-commit' \
  | python3 "$(dirname "$0")/no_comments.py" "$root"
