output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Command to update local kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "ecr_registry" {
  description = "ECR registry URL — pass as --registry to sol deploy"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_login_command" {
  description = "Command to authenticate Docker with ECR"
  value       = "aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "postgres_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = var.create_rds ? aws_db_instance.postgres[0].endpoint : null
  sensitive   = true
}

output "postgres_url" {
  description = "POSTGRES_URL for Sol services — set this in your CI secrets and sol.toml [infra.env]"
  value       = var.create_rds ? "postgresql://postgres:${var.db_password}@${aws_db_instance.postgres[0].endpoint}/app" : null
  sensitive   = true
}

output "route53_zone_id" {
  description = "Route53 hosted zone ID (needed for cert-manager DNS01 validation)"
  value       = var.create_route53_zone ? aws_route53_zone.main[0].zone_id : null
}

output "route53_nameservers" {
  description = "Nameservers to set at your domain registrar"
  value       = var.create_route53_zone ? aws_route53_zone.main[0].name_servers : null
}

output "cert_manager_irsa_arn" {
  description = "IAM role ARN for cert-manager — set in platform/infra/base as cert_manager_irsa_role_arn"
  value       = module.cert_manager_irsa.iam_role_arn
}

output "loki_s3_bucket" {
  description = "S3 bucket for durable Loki storage — set in platform/infra/base as loki_s3_bucket"
  value       = var.enable_durable_observability ? aws_s3_bucket.loki[0].bucket : null
}

output "loki_irsa_arn" {
  description = "IAM role ARN for Loki's S3 access — set in platform/infra/base as loki_irsa_role_arn"
  value       = var.enable_durable_observability ? module.loki_irsa[0].iam_role_arn : null
}

output "thanos_s3_bucket" {
  description = "S3 bucket for durable Prometheus/Thanos storage — set in platform/infra/base as thanos_s3_bucket"
  value       = var.enable_durable_observability ? aws_s3_bucket.thanos[0].bucket : null
}

output "thanos_irsa_arn" {
  description = "IAM role ARN for Thanos S3 access — set in platform/infra/base as thanos_irsa_role_arn"
  value       = var.enable_durable_observability ? module.thanos_irsa[0].iam_role_arn : null
}

data "aws_caller_identity" "current" {}
