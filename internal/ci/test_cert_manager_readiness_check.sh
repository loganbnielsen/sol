#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$repo_root/internal/ci/check_cert_manager_readiness.sh"
real_tf="$repo_root/platform/cloud/modules/platform/main.tf"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

mkcase() {
  local name="$1" root="$scratch/$name"
  mkdir -p "$root/platform/cloud/modules/platform"
  cp "$real_tf" "$root/platform/cloud/modules/platform/main.tf"
  printf '%s' "$root"
}

reject() {
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

accept() {
  local name="$1" root
  root="$(mkcase "$name")"
  if ! "$guard" "$root" >"$scratch/$name.out" 2>&1; then
    echo "FAIL: the guard rejected the unmutated tree ($name):" >&2
    cat "$scratch/$name.out" >&2
    exit 1
  fi
  echo "  accepted: $name (unmutated)"
}

mutation() {
  reject "$1"
}

echo "check_cert_manager_readiness.sh mutations"

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

mutation check-disabled <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('    value = "10m"', '    value = "10m"\n  }\n\n  set {\n    name  = "startupapicheck.enabled"\n    value = "false"', 1)
p.write_text(s)
PY

mutation per-attempt-1m <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('    value = "10m"', '    value = "1m"', 1)
p.write_text(s)
PY

mutation release-wait-300 <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('  timeout = 1800', '  timeout = 300')
p.write_text(s)
PY

mutation release-wait-at-worst-case <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('  timeout = 1800', '  timeout = 1200')
p.write_text(s)
PY

mutation no-backoff-limit <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
block = '  set {\n    name  = "startupapicheck.backoffLimit"\n    value = "1"\n  }\n\n'
s = s.replace(block, '')
p.write_text(s)
PY

mutation wait-false <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('  wait = true', '  wait = false')
p.write_text(s)
PY

mutation no-crds <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('    value = "true"', '    value = "false"', 1)
p.write_text(s)
PY

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

mutation leader-election-kube-system <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('    value = kubernetes_namespace.cert_manager.metadata[0].name',
              '    value = "kube-system"', 1)
p.write_text(s)
PY

mutation leader-election-other-namespace <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('    value = kubernetes_namespace.cert_manager.metadata[0].name',
              '    value = "default"', 1)
p.write_text(s)
PY

mutation leader-election-literal-name <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('    value = kubernetes_namespace.cert_manager.metadata[0].name',
              '    value = "cert-manager"', 1)
p.write_text(s)
PY

mutation leader-election-wrong-reference <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('    value = kubernetes_namespace.cert_manager.metadata[0].name',
              '    value = kubernetes_namespace.ingress_nginx.metadata[0].name', 1)
p.write_text(s)
PY

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
