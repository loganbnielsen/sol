#!/usr/bin/env bash
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
if re.search(r'^\s*enable_autopilot\s*=', code, re.M):
    problems.append(
        'the cluster must not carry an enable_autopilot attribute at all: the google provider '
        "refuses it alongside remove_default_node_pool, and Sol states its substrate by not "
        'requesting Autopilot. Declaring the attribute -- even as false -- is a plan-time error '
        '(Attempt 15)')
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

code_only "$cluster" | grep -qE '^resource[[:space:]]+"google_container_node_pool"' \
  || fail "a Standard cluster needs a node pool, and the driver must own it"
code_only "$cluster" | grep -qE 'remove_default_node_pool[[:space:]]*=[[:space:]]*true' \
  || fail "the cluster's default node pool must be removed: Sol owns the pool it runs on"

for attribute in machine_type disk_size_gb; do
  code_only "$cluster" | grep -qE "^[[:space:]]*${attribute}[[:space:]]*=[[:space:]]*var\." \
    || fail "the node pool's ${attribute} must come from a driver variable, not a literal and not the target"
done
code_only "$cluster" | grep -qE '^[[:space:]]*node_count[[:space:]]*=[[:space:]]*var\.' \
  || fail "the node pool's count must come from a driver variable"

for name in node_count node_machine_type node_disk_gb; do
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

echo "GCP substrate: the driver provisions GKE Standard (no Autopilot request, no knob), owns a"
echo "               node pool with driver-defaulted sizing, and keeps its control plane regional"
