# Minimal-footprint override for live smoke-testing platform/cloud/aws/cluster/ --
# NOT for real workspaces. Two t3.medium nodes are the smallest shape we've
# found that can run the full base platform stack in EKS; EKS control plane's
# flat hourly charge still applies regardless of node sizing.
#
# Usage: internal/qualification/aws/live-smoke.sh, which generates an untracked
# smoke target (sol/qual2/aws/us-east-1.yml in the workspace, cluster and
# platform only) pointing here by absolute path, and removes it on exit:
#
#   AWS_PROFILE=<profile> CLUSTER=sol-smoke-<you> \
#     internal/qualification/aws/live-smoke.sh
#
# The smoke target omits the Postgres resource, so Sol derives create_rds=false
# from the merged config.

# Required by variables.tf but unused: create_route53_zone is false below, so
# this value is never read. Placeholder only — no real domain needed.
base_domain = "smoke-test.invalid"

# Enough room for EKS system add-ons plus cert-manager, ingress-nginx, Argo CD,
# Redpanda, Loki/Grafana, Prometheus, and pushgateway.
node_instance_types = ["t3.medium"]
node_min_size       = 2
node_max_size       = 2
node_desired_size   = 2

# Single NAT gateway is already the default (ha_nat_gateway = false); kept
# explicit here so this file is a complete picture of the smoke-test shape.
ha_nat_gateway = false

# CRITICAL: the variables.tf default is `true`, which makes `terraform
# destroy` refuse to delete the RDS instance — the #1 way a "cheap" smoke
# test turns into an orphaned ~$25-35/month RDS bill nobody notices.
rds_deletion_protection = false

# Must be stated explicitly. These were one knob until HARDEN-002 finding 9:
# `skip_final_snapshot` was `!rds_deletion_protection`, so the line above used to
# imply "no final snapshot" as a side effect. They are independent now — correct
# for production, where permitting destruction must not silently discard the
# data — which means a disposable target has to say so itself. Left unset, every
# smoke teardown would strand a snapshot the destroy-verification does not look
# for, and the second run of this fixed cluster_name would fail outright with
# DBSnapshotAlreadyExists.
rds_skip_final_snapshot = true

# No real DNS to manage for a smoke test — skip creating a Route53 zone
# (avoids both the zone and needing a real domain you control).
create_route53_zone = false

# No service images to push for a smoke test.
ecr_repositories = []
