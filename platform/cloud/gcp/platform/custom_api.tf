# Stable interface for workspace-owned Terraform composed into this root.
locals {
  sol_target = {
    provider         = "gcp"
    base_domain      = var.base_domain
    cluster_issuer   = var.cluster_issuer
    platform_profile = var.platform_profile
  }
}
