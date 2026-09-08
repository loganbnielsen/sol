variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "GKE cluster name and resource name prefix (e.g. acme-prod)"
  type        = string
}

variable "base_domain" {
  description = "Base domain for the cluster (e.g. acme.com)"
  type        = string
}

# VPC CIDRs
variable "nodes_cidr" {
  type    = string
  default = "10.0.0.0/20"
}

variable "pods_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "services_cidr" {
  type    = string
  default = "10.2.0.0/20"
}

variable "master_cidr" {
  description = "CIDR for the GKE control plane (must be /28, cannot overlap other ranges)"
  type        = string
  default     = "172.16.0.0/28"
}

# Cloud SQL
variable "sql_tier" {
  description = "Cloud SQL machine tier"
  type        = string
  default     = "db-g1-small"
}

variable "sql_disk_gb" {
  type    = number
  default = 20
}

variable "sql_high_availability" {
  description = "Enable Cloud SQL high availability (REGIONAL). Doubles cost."
  type        = bool
  default     = false
}

variable "sql_deletion_protection" {
  description = "Enable Cloud SQL deletion protection."
  type        = bool
  default     = true
}

variable "db_password" {
  description = "PostgreSQL admin password"
  type        = string
  sensitive   = true
}

# DNS
variable "create_dns_zone" {
  description = "Create a new Cloud DNS managed zone for base_domain."
  type        = bool
  default     = true
}

# Durable observability (OBS-006/OBS-007, GCP side of the AWS S3+IRSA pair — INFRA-003)
variable "enable_durable_observability" {
  description = "Provision GCS buckets + Workload Identity service accounts for durable Loki (OBS-006) and Thanos-backed Prometheus (OBS-007) storage. Pair with platform/infra/base's observability_backend = \"self_hosted_durable\". Mirrors platform/infra/aws's enable_durable_observability."
  type        = bool
  default     = false
}

variable "loki_retention_days" {
  description = "GCS lifecycle retention (days) for durable Loki logs."
  type        = number
  default     = 90
  validation {
    condition     = var.loki_retention_days >= 1 && floor(var.loki_retention_days) == var.loki_retention_days
    error_message = "loki_retention_days must be a whole number of days >= 1."
  }
}
