# Minimal-footprint override for live smoke-testing platform/infra/aws/ —
# NOT for real workspaces. Two t3.medium nodes are the smallest shape we've
# found that can run the full base platform stack in EKS; EKS control plane's
# flat hourly charge still applies regardless of node sizing.
#
# Usage:
#   sol cloud apply dev/aws/us-east-1 \
#     --var cluster_name=sol-smoke-<you>
#
# cluster_name is deliberately not set here — pick a unique cluster_name per
# run. When using `sol cloud plan dev/aws/us-east-1`, Sol derives
# create_rds=false from the merged Sol config because that target omits the
# Postgres resource.

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

# No real DNS to manage for a smoke test — skip creating a Route53 zone
# (avoids both the zone and needing a real domain you control).
create_route53_zone = false

# No service images to push for a smoke test.
ecr_repositories = []
