variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name and resource name prefix (e.g. acme-prod)"
  type        = string
}

variable "base_domain" {
  description = "Base domain for the cluster (e.g. acme.com). Subdomains are managed via Route53."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.36"
}

# VPC
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "ha_nat_gateway" {
  description = "Deploy one NAT gateway per AZ (true) vs one shared gateway (false). Single gateway saves ~$100/month for dev clusters."
  type        = bool
  default     = false
}

# Node group
variable "node_instance_types" {
  description = "EC2 instance types for the EKS managed node group"
  type        = list(string)
  default     = ["m6i.large"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 10
}

variable "node_desired_size" {
  type    = number
  default = 3
}

# ECR
variable "ecr_repositories" {
  description = "List of service names to create ECR repositories for, e.g. [\"charge-svc\", \"notify-worker\"]"
  type        = list(string)
  default     = []
}

# RDS
variable "create_rds" {
  description = "Create an RDS PostgreSQL instance. Disable for low-cost substrate smoke tests."
  type        = bool
  default     = true
}

variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.small"
}

variable "rds_storage_gb" {
  description = "Allocated storage in GB for RDS"
  type        = number
  default     = 20
}

variable "db_password" {
  description = "PostgreSQL admin password"
  type        = string
  sensitive   = true
  default     = ""
}

variable "rds_deletion_protection" {
  description = "Enable RDS deletion protection. Set false to allow terraform destroy."
  type        = bool
  default     = true
}

# Route53
variable "create_route53_zone" {
  description = "Create a new Route53 hosted zone for base_domain. Set false if the zone already exists."
  type        = bool
  default     = true
}

# Tags applied to all resources
variable "tags" {
  type    = map(string)
  default = {}
}

# Durable observability (OBS-006/OBS-007)
variable "enable_durable_observability" {
  description = "Provision S3 buckets + IRSA roles for durable Loki (OBS-006) and Thanos-backed Prometheus (OBS-007) storage. Pair with platform/infra/base's observability_backend = \"self_hosted_durable\"."
  type        = bool
  default     = false
}

variable "loki_retention_days" {
  description = "S3 lifecycle retention for durable Loki logs."
  type        = number
  default     = 90
  validation {
    condition     = var.loki_retention_days >= 1 && floor(var.loki_retention_days) == var.loki_retention_days
    error_message = "loki_retention_days must be a whole number of days >= 1."
  }
}
