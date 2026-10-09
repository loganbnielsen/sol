# Stable interface for workspace-owned Terraform composed into this root.
# Keep the keys and their meanings provider-neutral across supported drivers.
locals {
  sol_target = {
    provider           = "aws"
    region             = var.region
    cluster_name       = module.eks.cluster_name
    cluster_endpoint   = module.eks.cluster_endpoint
    network_id         = module.vpc.vpc_id
    private_subnet_ids = module.vpc.private_subnets
  }
}
