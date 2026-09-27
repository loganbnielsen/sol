import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "internal/ci/check_cert_manager_readiness.py"
MAIN_TF = "platform/cloud/modules/platform/main.tf"
LEADER = "    value = kubernetes_namespace.cert_manager.metadata[0].name"
TIMEOUT_SET = '''  set {
    name  = "startupapicheck.timeout"
    value = "10m"
  }

'''
BACKOFF_SET = '''  set {
    name  = "startupapicheck.backoffLimit"
    value = "1"
  }

'''
LEADER_SET = '''  set {
    name  = "global.leaderElection.namespace"
    value = kubernetes_namespace.cert_manager.metadata[0].name
  }
'''
NAMESPACE = '''resource "kubernetes_namespace" "cert_manager" {
  metadata { name = "cert-manager" }
}'''

CASES = [
    ("pre-fix", [(TIMEOUT_SET + BACKOFF_SET, ""), ("  timeout = 1800\n", ""), ("  wait = true\n", "")]),
    ("check-disabled", [('    value = "10m"', '    value = "10m"\n  }\n\n  set {\n    name  = "startupapicheck.enabled"\n    value = "false"')]),
    ("per-attempt-1m", [('    value = "10m"', '    value = "1m"')]),
    ("release-wait-300", [("  timeout = 1800", "  timeout = 300")]),
    ("release-wait-at-worst-case", [("  timeout = 1800", "  timeout = 1200")]),
    ("no-backoff-limit", [(BACKOFF_SET, "")]),
    ("wait-false", [("  wait = true", "  wait = false")]),
    ("no-crds", [('    value = "true"', '    value = "false"')]),
    ("no-leader-election-namespace", [(LEADER_SET, "")]),
    ("leader-election-kube-system", [(LEADER, '    value = "kube-system"')]),
    ("leader-election-other-namespace", [(LEADER, '    value = "default"')]),
    ("leader-election-literal-name", [(LEADER, '    value = "cert-manager"')]),
    ("leader-election-wrong-reference", [(LEADER, "    value = kubernetes_namespace.ingress_nginx.metadata[0].name")]),
    ("cert-manager-namespace-renamed", [(NAMESPACE, NAMESPACE.replace('"cert-manager"', '"cert-manager-2"'))]),
]


def tree(scratch, name):
    root = scratch / name
    (root / MAIN_TF).parent.mkdir(parents=True)
    shutil.copy(REPO / MAIN_TF, root / MAIN_TF)
    return root


def verdict(root):
    run = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    return run.returncode, run.stdout + run.stderr


def main():
    print("check_cert_manager_readiness mutations")
    with tempfile.TemporaryDirectory() as scratch:
        for name, replacements in CASES:
            root = tree(Path(scratch), name)
            path = root / MAIN_TF
            text = path.read_text()
            for old, new in replacements:
                if old not in text:
                    sys.exit(f"FAIL: the '{name}' mutation's anchor no longer matches {MAIN_TF}: {old!r}")
                text = text.replace(old, new, 1)
            path.write_text(text)
            rc, output = verdict(root)
            if rc == 0:
                sys.exit(f"FAIL: the guard accepted the '{name}' mutation:\n{output}")
            print(f"  rejected: {name} -- {output.splitlines()[0] if output else ''}")
        rc, output = verdict(tree(Path(scratch), "real-tree"))
        if rc != 0:
            sys.exit(f"FAIL: the guard rejected the unmutated tree (real-tree):\n{output}")
        print("  accepted: real-tree (unmutated)")
    print("check_cert_manager_readiness: all mutations rejected, unmutated tree accepted")


main()
