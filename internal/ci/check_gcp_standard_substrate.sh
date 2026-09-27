#!/usr/bin/env bash
# INFRA-093 / FND-0064: the GCP driver provisions GKE Standard, and the profile refuses Autopilot.
#
# Two things this guard is careful *not* to do, because both would fossilize a qualification
# default into the architectural definition of GCP support:
#
#   - it does not assert today's numbers. `3 x e2-standard-2` with 100 GiB disks is the driver's
#     initial supported topology (DEC-049), recorded as the variables' defaults, and changing it
#     deliberately must not trip this check. What it asserts is *ownership*: those values come from
#     variables in the driver, not from the target contract and not hard-coded in the resource.
#   - it does not assert that the pool is pinned to one zone as an architectural fact. It asserts
#     the cluster's control plane stays regional -- every call site resolves it with `--region`,
#     and churning that is not what the substrate switch is about -- and leaves the pool's zone
#     placement to the driver's own configuration, where it is a cost decision.
#
# What it does assert is the product contract:
#
#   1. the driver does not request Autopilot, and nothing in the driver can turn it back on;
#   2. a Standard cluster has a node pool Sol owns, and no default pool left behind;
#   3. the pool's sizing comes from driver-owned variables that declare defaults, and appears
#      nowhere in the target contract;
#   4. the control plane stays at `var.region`.
#
# Usage: internal/ci/check_gcp_standard_substrate.sh [repo-root]
set -euo pipefail

root="${1:-.}"
cluster="$root/platform/cloud/gcp/cluster/main.tf"
variables="$root/platform/cloud/gcp/cluster/variables.tf"

for path in "$cluster" "$variables"; do
  if [ ! -f "$path" ]; then
    echo "FAIL: missing $path" >&2
    exit 1
  fi
done

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

code_only() { grep -vE '^[[:space:]]*#' "$1"; }

# 1. what the *cluster resource itself* declares. Scoped to the block on purpose: a sibling
#    resource with `location = var.region` would otherwise satisfy a control-plane check on its
#    own, which is how this check first passed a mutation that made the cluster zonal.
python3 - "$cluster" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r'resource\s+"google_container_cluster"\s+"main"\s*\{', text)
assert match, 'the GCP cluster root declares no google_container_cluster "main"'
body_start = match.end()
depth, i = 1, body_start
while depth and i < len(text):
    if text[i] == '{':
        depth += 1
    elif text[i] == '}':
        depth -= 1
    i += 1
body = text[body_start:i]
code = '\n'.join(l for l in body.splitlines() if not l.strip().startswith('#'))
problems = []
if not re.search(r'^\s*enable_autopilot\s*=\s*false\s*$', code, re.M):
    problems.append(
        'the cluster must declare enable_autopilot = false: the profile provisions and supports '
        'GKE Standard, and Autopilot refuses the node-level capabilities its components require '
        '(FND-0064)')
if re.search(r'enable_autopilot\s*=\s*var\.', code):
    problems.append(
        'enable_autopilot must not be a variable: the substrate is a property of the driver, not '
        'a user knob')
if not re.search(r'^\s*remove_default_node_pool\s*=\s*true\s*$', code, re.M):
    problems.append(
        "the cluster's default node pool must be removed: Sol owns the pool it runs on")
if not re.search(r'^\s*location\s*=\s*var\.region\s*$', code, re.M):
    problems.append(
        "the cluster's control plane stays regional (location = var.region): every call site "
        'resolves it with --region, and making the control plane zonal is not what the substrate '
        'switch is about')
for problem in problems:
    print('FAIL: ' + problem)
sys.exit(1 if problems else 0)
PY

# 2. Standard needs a pool Sol owns, and no leftover default pool
code_only "$cluster" | grep -qE '^resource[[:space:]]+"google_container_node_pool"' \
  || fail "a Standard cluster needs a node pool, and the driver must own it"
code_only "$cluster" | grep -qE 'remove_default_node_pool[[:space:]]*=[[:space:]]*true' \
  || fail "the cluster's default node pool must be removed: Sol owns the pool it runs on"

# 3. ownership: the pool's sizing comes from variables, and the target contract has no such keys
for attribute in machine_type disk_size_gb; do
  code_only "$cluster" | grep -qE "^[[:space:]]*${attribute}[[:space:]]*=[[:space:]]*var\." \
    || fail "the node pool's ${attribute} must come from a driver variable, not a literal and not the target"
done
code_only "$cluster" | grep -qE '^[[:space:]]*node_count[[:space:]]*=[[:space:]]*var\.' \
  || fail "the node pool's count must come from a driver variable"

for name in node_count node_machine_type node_disk_gb; do
  # Built as one string rather than nested in the pattern: quoting a quoted pattern is how this
  # check first matched nothing and reported a falsified failure.
  declared="variable \"${name}\""
  grep -qF "$declared" "$variables" \
    || fail "${name} must be declared in the driver's variables"
  grep -qE '^[[:space:]]*default[[:space:]]*=' "$variables" \
    || fail "${name} must declare a default: these are driver-owned defaults, not required inputs"
done

if [ -d "$root/cli/lib/config" ] \
   && grep -rqE 'node_count|node_machine_type|node_disk_gb' "$root/cli/lib/config" 2>/dev/null; then
  fail "node sizing must not appear in the target contract: what should control sizing is a design decision, and not one to infer from a qualification run"
fi

echo "GCP substrate: the driver provisions GKE Standard (enable_autopilot = false, no knob), owns a"
echo "               node pool with driver-defaulted sizing, and keeps its control plane regional"
