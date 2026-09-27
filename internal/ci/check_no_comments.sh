#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

git -C "$root" ls-files -z -- '*.ml' '*.mli' '*.sh' '*.bash' '*.tf' '*.tfvars' '*.ts' '*.py' \
  '*dune' 'dune-project' 'dune-workspace' '*Dockerfile' \
  'internal/tooling/hooks/pre-commit' 'internal/tooling/hooks/post-commit' 'internal/ci/lifecycle_fakes/*' \
  | python3 "$(dirname "$0")/no_comments.py" "$root"
