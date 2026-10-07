"""The broker name the platform advertises must be one its certificate identifies.

Redpanda's chart builds a broker's advertised DNS name from `clusterDomain`
*without* trimming its trailing dot, while it trims that dot when it renders the
certificate's SANs (`redpanda/templates/_helpers.go.tpl` builds
`<service>.<namespace>.svc.<clusterDomain>` and `_certs.go.tpl` does
`trimSuffix "." .Values.clusterDomain`). The chart's own default is
`cluster.local.`, so the brokers advertise
`<broker>.<service>.<namespace>.svc.cluster.local.` -- a name no SAN matches.

A client that verifies the broker's hostname therefore fails the TLS handshake
with a bare `certificate verify failed`, which reads like a trust-store problem:
librdkafka defaults `ssl.endpoint.identification.algorithm` to `https` from 2.0,
so the workloads could not consume Kafka while `openssl s_client` against the same
broker, with the same CA, verified fine (sol-fab/sol#1279).

Sol owns the platform values, so it pins the domain in the form the chart's own
certificates use; leaving the chart default returns the defect.
"""

import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
components_json = root / "platform/shared/components.json"
platform_module = root / "platform/cloud/modules/platform/main.tf"

problems = []
for path, what in (
    (components_json, "the platform components"),
    (platform_module, "the platform module"),
):
    if not path.exists():
        problems.append(f"{what} is missing: {path}")
if problems:
    print("\n".join("FAIL: " + p for p in problems))
    sys.exit(1)

try:
    components = json.loads(components_json.read_text())
except json.JSONDecodeError as error:
    print(f"FAIL: {components_json} is not valid JSON: {error}")
    sys.exit(1)

common = components.get("redpanda", {}).get("common")
if not isinstance(common, dict):
    problems.append("platform/shared/components.json declares no redpanda common values")
else:
    domain = common.get("clusterDomain")
    if domain is None:
        problems.append(
            "the redpanda values do not pin clusterDomain, so the chart default "
            "'cluster.local.' returns and every broker advertises a name ending in a dot "
            "(sol-fab/sol#1279)"
        )
    elif not isinstance(domain, str) or not domain.strip():
        problems.append(f"the redpanda clusterDomain is not a non-empty string: {domain!r}")
    elif domain != domain.strip() or domain.endswith("."):
        problems.append(
            f"the redpanda clusterDomain is {domain!r}; a trailing dot (or surrounding "
            "space) makes the advertised broker name differ from the certificate's SANs "
            "(sol-fab/sol#1279)"
        )
    elif domain != "cluster.local":
        problems.append(
            f"the redpanda clusterDomain is {domain!r}; the platform's own rendered names "
            "use cluster.local, and a different domain would not resolve in-cluster"
        )

# The value only binds the chart if the module hands it the declared component
# values: a refactor that stops passing them would silently restore the default.
module_text = platform_module.read_text()
if "local.platform_components.redpanda.common" not in module_text:
    problems.append(
        "platform/cloud/modules/platform/main.tf no longer passes "
        "local.platform_components.redpanda.common to the redpanda release"
    )

if problems:
    print("\n".join("FAIL: " + p for p in problems))
    sys.exit(1)
print("redpanda clusterDomain is pinned to the form the platform's certificates identify")
