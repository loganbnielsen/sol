#!/usr/bin/env bash
# INFRA-090 / FND-0062: Sol's declared minimum persistent-disk requirement must still match the
# platform declarations it comes from.
#
# The lifecycle compares a *provider observation* against Sol's *own declaration*
# (`Sol_cli_platform_storage`). A declaration that has drifted from the Terraform it describes
# is worse than no check at all, because it reads as a guarantee: it would let a run start with
# a floor that is too low, which is exactly the false pass FND-0062's finding was about.
#
# What this can check, it checks:
#   - the prometheus part is the Terraform variable's default, to the GiB;
#   - the components whose persistence Sol enables still have it enabled, so a part cannot go
#     stale because the volume disappeared rather than because the size changed;
#   - every part says where its number came from -- including the ones (loki, alertmanager)
#     whose size is the chart's default, which Sol does not own and therefore cannot be
#     cross-checked here, only declared honestly.
#
# Usage: internal/ci/check_platform_storage_requirement.sh [repo-root]
set -euo pipefail

root="${1:-.}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: this check needs python3" >&2
  exit 1
fi

python3 - "$root" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
module = root / 'platform/cloud/modules/platform/main.tf'
declaration = root / 'cli/lib/cloud/sol_cli_platform_storage.ml'
variables = sorted(root.glob('platform/cloud/*/platform/variables.tf'))

problems = []

for path, what in ((module, 'the platform module'), (declaration, 'the declaration')):
    if not path.exists():
        problems.append(f'{what} is missing: {path}')
if problems:
    print('\n'.join('FAIL: ' + p for p in problems))
    sys.exit(1)

declared = {}
text = declaration.read_text()
for component, gib, provenance in re.findall(
        r'\{\s*component\s*=\s*"([^"]+)"\s*;\s*gib\s*=\s*(\d+)\s*;\s*provenance\s*=\s*"((?:[^"\\]|\\.)*)"', text, re.S):
    declared[component] = (int(gib), provenance)
if not declared:
    problems.append('the declaration lists no parts at all')

# 1. every part says where its number came from
for component, (_gib, provenance) in declared.items():
    if not provenance.strip():
        problems.append(f'the part "{component}" states no provenance')

# 2. persistence Sol's declaration assumes must still be enabled by the module. Sol sets no
#    size anywhere, so what it can go stale against is *enabled*, not a number.
module_text = module.read_text()
for needle, what in (
    # The quoted form is the `set` block's name; the module's comment mentions the same value
    # unquoted, so requiring the quotes is what makes this a check on the configuration.
    ('"singleBinary.persistence.enabled"', "loki's singleBinary.persistence.enabled"),
    ('alertmanager', 'the alertmanager release'),
    ('prometheus', 'the prometheus release'),
):
    if needle not in module_text:
        problems.append(f'the module no longer declares {what}, which the declaration assumes')

# 3. Every size in the declaration must be attributed to the chart (or to a live observation),
#    because Sol sets no size. A provenance that names a Sol-side variable instead would be a
#    claim Sol cannot back -- that is the mistake this rule exists to catch, and it was made
#    once while writing this very file.
for component, (_gib, provenance) in declared.items():
    # The source wraps long strings with continuations; the reader cares about the words.
    lowered = ' '.join(provenance.split()).lower()
    if 'chart default' not in lowered and 'observed live' not in lowered:
        problems.append(
            f'the part "{component}" does not attribute its size to the chart or to a live '
            f'observation, but Sol declares no size of its own')
    if 'var.' in lowered and 'chart default' not in lowered:
        problems.append(
            f'the part "{component}" attributes its size to a Sol variable, but Sol sets no '
            f'storage size; either one is declared, or the provenance is wrong')

if problems:
    for problem in problems:
        print('FAIL: ' + problem)
    print(f'platform storage requirement: {len(problems)} problem(s)')
    sys.exit(1)

parts = ', '.join(f'{name} {gib} GiB' for name, (gib, _p) in sorted(declared.items()))
print(
    'platform storage requirement: ' + parts + '; every part attributes its size to the chart, '
    'and every component the declaration assumes is still enabled by the module')
PY
