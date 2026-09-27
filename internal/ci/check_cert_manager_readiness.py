import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import tfconfig

EXPECTED_REF = "kubernetes_namespace.cert_manager.metadata[0].name"


def fail(message):
    sys.exit(f"FAIL: {message}")


def seconds(value):
    match = re.fullmatch(r"(\d+)([hms]?)", str(value))
    if not match:
        return None
    return int(match.group(1)) * {"h": 3600, "m": 60, "s": 1, "": 1}[match.group(2)]


def plain(value):
    if tfconfig.is_string_literal(value):
        return tfconfig.unquote(value)
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, str) and value.startswith("${") and value.endswith("}"):
        return value[2:-1]
    return value if value is None else str(value)


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    main_tf = root / "platform/cloud/modules/platform/main.tf"
    if not main_tf.is_file():
        fail(f"{main_tf} is missing")
    found = tfconfig.resources(main_tf, kinds=("resource",))
    release = next((r for r in found if r.type == "helm_release" and r.name == "cert_manager"), None)
    if release is None:
        fail(f"no helm_release.cert_manager block in {main_tf}")
    sets = {tfconfig.unquote(s.get("name")): plain(s.get("value")) for s in tfconfig.blocks(release.body, "set")}
    if sets.get("installCRDs") != "true":
        fail("cert-manager must install its CRDs (installCRDs = true)")
    if sets.get("startupapicheck.enabled") in ("false", "False"):
        fail("startupapicheck must not be disabled: it is cert-manager's readiness contract")
    per_attempt_raw = sets.get("startupapicheck.timeout")
    if not per_attempt_raw:
        fail("startupapicheck.timeout must be set explicitly (the chart default is 1m)")
    per_attempt = seconds(per_attempt_raw)
    if per_attempt is None:
        fail(f"startupapicheck.timeout is not a duration this guard understands: '{per_attempt_raw}'")
    if per_attempt < 300:
        fail(f"startupapicheck.timeout is {per_attempt}s; a first install needs at least 300s")
    backoff_raw = sets.get("startupapicheck.backoffLimit")
    if not backoff_raw:
        fail("startupapicheck.backoffLimit must be set explicitly")
    if not re.fullmatch(r"\d+", backoff_raw):
        fail(f"startupapicheck.backoffLimit is not a non-negative integer: '{backoff_raw}'")
    backoff = int(backoff_raw)
    release_timeout = plain(release.body.get("timeout"))
    if release_timeout is None:
        fail("the release must set an explicit timeout (the provider default, 300s, bounds the post-install check)")
    if not re.fullmatch(r"\d+", release_timeout):
        fail(f"the release timeout is not a number of seconds: '{release_timeout}'")
    worst_case = (backoff + 1) * per_attempt
    if int(release_timeout) <= worst_case:
        fail(
            f"the release timeout ({release_timeout}s) must exceed the check's worst case ({worst_case}s = "
            f"(backoffLimit {backoff} + 1) x {per_attempt}s)"
        )
    if plain(release.body.get("wait", True)) != "true":
        fail("the release must wait for its resources (wait = true)")
    leader_election = sets.get("global.leaderElection.namespace")
    if not leader_election:
        fail(
            "global.leaderElection.namespace must be declared: the chart default is kube-system, which GKE "
            "Autopilot manages and denies, so cert-manager never leads and its post-install check cannot "
            "pass (FND-0060 / Attempt 10)"
        )
    if "kube-system" in leader_election:
        fail(
            f"global.leaderElection.namespace must not be kube-system (found '{leader_election}'): Autopilot "
            "denies workloads the create verb in that namespace, so leader election can never succeed there"
        )
    if leader_election != EXPECTED_REF:
        fail(
            f"global.leaderElection.namespace must be {EXPECTED_REF} (found '{leader_election}'): a literal, "
            "another namespace, or another resource would be a second source of truth for the namespace "
            "cert-manager is installed into"
        )
    namespace = next((r for r in found if r.type == "kubernetes_namespace" and r.name == "cert_manager"), None)
    if namespace is None:
        fail(
            f"the leader-election namespace references kubernetes_namespace.cert_manager, which {main_tf} does not define"
        )
    namespace_name = plain((tfconfig.blocks(namespace.body, "metadata") or [{}])[0].get("name"))
    if namespace_name != "cert-manager":
        fail(
            f"kubernetes_namespace.cert_manager names '{namespace_name}', so the leader-election namespace does "
            "not resolve to cert-manager"
        )
    if shutil.which("terraform"):
        if subprocess.run(["terraform", "fmt", "-check", str(main_tf)], capture_output=True).returncode != 0:
            fail(f"{main_tf} is not terraform-fmt clean")
    print(
        f"cert-manager readiness: check enabled, {per_attempt}s per attempt x {backoff + 1} attempt(s) <= "
        f"{release_timeout}s release wait; wait = true, CRDs from the chart; leader election in "
        f"{namespace_name} (by reference), never kube-system."
    )


main()
