"""Qualification must probe the endpoint the runtime declares, not one it never serves.

The framework's service contract declares its operational endpoints in
`framework/ocaml/sol-svc/lib/service.ml`: the built-in routes are `/healthz` and
`/readyz`. The live harnesses reach the deployed service through the qualification
transport and probe its health before they drive the transaction; a probe that
names any other path gets a 404 and the run reports the service as unreachable
while it is healthy (sol-fab/sol#1283).

This guard keeps the two in step in both directions: it reads the declaration
rather than hardcoding a path, and it fails if a harness stops probing it.
"""

import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
declaration = root / "framework/ocaml/sol-svc/lib/service.ml"
probes = [
    root / "internal/qualification/aws/transport-transaction.sh",
    root / "internal/qualification/aws/app-transaction.sh",
    root / "internal/qualification/gcp/live-qual.sh",
]
qualification = root / "internal/qualification"

problems = []
for path in [declaration, *probes]:
    if not path.exists():
        problems.append(f"missing: {path}")
if problems:
    print("\n".join("FAIL: " + p for p in problems))
    sys.exit(1)

# The declared operational endpoints: the built-in route match in the service.
declared = set()
for line in declaration.read_text().splitlines():
    if "/healthz" in line and "/readyz" in line:
        declared.update(re.findall(r'"(/[a-z]+)"', line))
if not declared:
    print(f"FAIL: {declaration} no longer declares the built-in operational endpoints")
    sys.exit(1)

health = sorted(p for p in declared if "health" in p)
if len(health) != 1:
    print(f"FAIL: the service declares {health}; the harnesses probe one health endpoint")
    sys.exit(1)
health = health[0]

for path in probes:
    text = path.read_text()
    if f"{health}" not in text:
        problems.append(
            f"{path.relative_to(root)} does not probe the runtime's declared health "
            f"endpoint {health} (sol-fab/sol#1283)"
        )

# A path the service never serves looks like a working probe until it is run.
# Third-party APIs the harnesses also probe (the monitoring stack's `/api/...`)
# are not Sol services and are out of scope here.
for path in sorted(qualification.rglob("*.sh")):
    for match in re.finditer(r"(?<!api)/health[a-z]*", path.read_text()):
        if match.group(0) not in declared:
            problems.append(
                f"{path.relative_to(root)} probes {match.group(0)}, which "
                f"{declaration.relative_to(root)} does not declare"
            )

if problems:
    print("\n".join("FAIL: " + p for p in problems))
    sys.exit(1)
print(f"qualification probes the declared health endpoint {health}")
