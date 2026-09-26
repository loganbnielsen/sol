#!/usr/bin/env bash
# Mutation self-test for check_cert_manager_readiness.sh (FND-0010).
#
# The strongest case here is the first one: the *pre-fix* configuration -- the chart's
# defaults, with no release timeout -- must be rejected. That is the configuration every
# GCP attempt ran, so if this test ever goes green on it, the guard has stopped protecting
# anything.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$repo_root/internal/ci/check_cert_manager_readiness.sh"
real_tf="$repo_root/platform/cloud/modules/platform/main.tf"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

mkcase() { # mkcase <name> -> echoes the temp root
  local name="$1" root="$scratch/$name"
  mkdir -p "$root/platform/cloud/modules/platform"
  cp "$real_tf" "$root/platform/cloud/modules/platform/main.tf"
  printf '%s' "$root"
}

reject() { # reject <name>  (a python mutation script on stdin; argv[1] is the .tf)
  local name="$1" root rc mutfile
  root="$(mkcase "$name")"
  mutfile="$scratch/$name.mutation.py"
  cat >"$mutfile"
  python3 "$mutfile" "$root/platform/cloud/modules/platform/main.tf"
  set +e
  "$guard" "$root" >"$scratch/$name.out" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: the guard accepted the '$name' mutation:" >&2
    cat "$scratch/$name.out" >&2
    exit 1
  fi
  echo "  rejected: $name -- $(head -1 "$scratch/$name.out")"
}

accept() { # accept <name>
  local name="$1" root
  root="$(mkcase "$name")"
  if ! "$guard" "$root" >"$scratch/$name.out" 2>&1; then
    echo "FAIL: the guard rejected the unmutated tree ($name):" >&2
    cat "$scratch/$name.out" >&2
    exit 1
  fi
  echo "  accepted: $name (unmutated)"
}

mutation() { # mutation <name>  -- writes the mutation script, then asserts rejection
  reject "$1"
}

echo "check_cert_manager_readiness.sh mutations"

# 1. The configuration the live runs actually used: chart defaults, no release timeout.
mutation pre-fix <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('''  set {
    name  = "startupapicheck.timeout"
    value = "10m"
  }

  set {
    name  = "startupapicheck.backoffLimit"
    value = "1"
  }

''', '')
s = s.replace('  timeout = 1800\n', '')
s = s.replace('  wait = true\n', '')
p.write_text(s)
PY

# 2. Disabling the check: the "fix" this guard must never allow.
mutation check-disabled <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('    value = "10m"', '    value = "10m"\n  }\n\n  set {\n    name  = "startupapicheck.enabled"\n    value = "false"', 1)
p.write_text(s)
PY

# 3. A per-attempt budget back at the chart default.
mutation per-attempt-1m <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('    value = "10m"', '    value = "1m"', 1)
p.write_text(s)
PY

# 4. A release wait shorter than the check's worst case (the live failure: the 300s default).
mutation release-wait-300 <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('  timeout = 1800', '  timeout = 300')
p.write_text(s)
PY

# 5. A release wait exactly at the worst case: not strictly greater, so still rejected.
mutation release-wait-at-worst-case <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('  timeout = 1800', '  timeout = 1200')
p.write_text(s)
PY

# 6. No explicit retry bound.
mutation no-backoff-limit <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
block = '  set {\n    name  = "startupapicheck.backoffLimit"\n    value = "1"\n  }\n\n'
s = s.replace(block, '')
p.write_text(s)
PY

# 7. The wait turned off, so the chart's resources may not be ready before its check runs.
mutation wait-false <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('  wait = true', '  wait = false')
p.write_text(s)
PY

# 8. The CRDs no longer installed by the chart.
mutation no-crds <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('    value = "true"', '    value = "false"', 1)
p.write_text(s)
PY

# ── FND-0060: leader election must be cert-manager's own namespace, by reference ──────
# The four shapes the ticket names (declared at all, kube-system, another namespace, omitted)
# plus the one that only a reference-checking guard catches: the right *name* written as a
# literal, which is a second source of truth for the namespace Sol installs into.

# 9. Omitted entirely: the chart default (kube-system) is what Attempt 10 ran.
mutation no-leader-election-namespace <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
block = '''  set {
    name  = "global.leaderElection.namespace"
    value = kubernetes_namespace.cert_manager.metadata[0].name
  }

'''
assert block in s, "leader-election set block not found"
s = s.replace(block, '', 1)
p.write_text(s)
PY

# 10. The chart's default, written out: Autopilot denies it, so this is the defect itself.
mutation leader-election-kube-system <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('    value = kubernetes_namespace.cert_manager.metadata[0].name',
              '    value = "kube-system"', 1)
p.write_text(s)
PY

# 11. Some other namespace: same class of mistake, different string.
mutation leader-election-other-namespace <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('    value = kubernetes_namespace.cert_manager.metadata[0].name',
              '    value = "default"', 1)
p.write_text(s)
PY

# 12. The right namespace as a literal: correct today, a second source of truth tomorrow.
mutation leader-election-literal-name <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('    value = kubernetes_namespace.cert_manager.metadata[0].name',
              '    value = "cert-manager"', 1)
p.write_text(s)
PY

# 13. A reference, but to the wrong namespace resource.
mutation leader-election-wrong-reference <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('    value = kubernetes_namespace.cert_manager.metadata[0].name',
              '    value = kubernetes_namespace.ingress_nginx.metadata[0].name', 1)
p.write_text(s)
PY

# 14. The reference kept, but the namespace it resolves to renamed: the guard must follow the
#     link rather than trusting the reference's spelling.
mutation cert-manager-namespace-renamed <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = '''resource "kubernetes_namespace" "cert_manager" {
  metadata { name = "cert-manager" }
}'''
assert old in s, "cert-manager namespace resource not found"
s = s.replace(old, old.replace('name = "cert-manager"', 'name = "cert-manager-2"'), 1)
p.write_text(s)
PY

accept real-tree

echo "check_cert_manager_readiness.sh: all mutations rejected, unmutated tree accepted"
