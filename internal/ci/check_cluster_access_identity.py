import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import tfconfig

ROOT = Path(__file__).resolve().parents[2]
DENIED = [
    "eks:CreateAccessEntry",
    "eks:DeleteAccessEntry",
    "eks:UpdateAccessEntry",
    "eks:AssociateAccessPolicy",
    "eks:DisassociateAccessPolicy",
    "iam:*",
]
MUTATION = re.compile(r"^(eks:(Create|Update|Delete|Associate|Disassociate)|iam:)")


def fail(message):
    sys.exit(f"check_cluster_access_identity: {message}")


def main():
    policy_file = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "platform/cloud/aws/bootstrap/main.tf"
    aws_root = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "platform/cloud/aws/cluster/main.tf"
    policy = next(
        (r for r in tfconfig.resources(policy_file, kinds=("data",))
         if r.type == "aws_iam_policy_document" and r.name == "cluster_access"),
        None,
    )
    if policy is None:
        fail("cluster_access policy is missing")
    statements = []
    for s in tfconfig.blocks(policy.body, "statement"):
        effect = tfconfig.unquote(s.get("effect", '"Allow"'))
        actions = [tfconfig.unquote(a) for a in s.get("actions", [])]
        statements.append((effect, actions))
    allowed = [a for effect, actions in statements if effect == "Allow" for a in actions]
    denied = [a for effect, actions in statements if effect == "Deny" for a in actions]
    if "eks:DescribeCluster" not in allowed:
        fail("steady-state identity cannot discover the cluster")
    for action in DENIED:
        if action not in denied:
            fail(f"steady-state explicit deny is missing {action}")
    if any(MUTATION.match(a) for a in allowed):
        fail("steady-state allow grants access-entry, policy-association, or IAM mutation")
    entries = [
        m.body.get("access_entries", "")
        for m in tfconfig.modules(aws_root)
        if m.name == "eks"
    ]
    owned = re.compile(r"platform_cluster_access\s*=\s*\{\s*principal_arn\s*=\s*var\.cluster_access_role_arn\b")
    if not any(owned.search(str(e)) for e in entries):
        fail("EKS access entry is not owned by cluster_access_role_arn")
    print("check_cluster_access_identity: provisioning and steady-state identities are structurally separate")


main()
