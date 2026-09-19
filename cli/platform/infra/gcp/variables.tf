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

# The GKE provider's own guard. See the resource: it defaults to true, so a
# target that never mentions it cannot be destroyed. Default true keeps a destroy
# driven directly against Terraform failing rather than deleting a cluster by
# surprise; `sol cloud destroy`'s Destroy policy sets it false for the teardown,
# exactly as it does for Cloud SQL.
variable "gke_deletion_protection" {
  description = "Enable the GKE provider's deletion protection on the cluster. Default true (a direct destroy fails rather than deleting a cluster); `sol cloud destroy` sets it false for the Destroy phase."
  type        = bool
  default     = true
}

# How long to wait, after the Cloud SQL instance is gone, before releasing the
# servicenetworking peering. Default 300s: live attempt 1 observed the peering
# still refusing ~2.5 minutes after the instance's delete completed, and GCP does
# not document the window. The number is a variable so a live observation can
# correct it without touching the graph's shape.
variable "sql_private_network_release_wait" {
  description = "How long to wait between the Cloud SQL instance's destruction and releasing its private-services peering, which GCP releases asynchronously."
  type        = string
  default     = "300s"
}

# The install window's privilege, named exactly as the AWS root names it. The
# mechanism underneath differs -- an IAM role assumed through an EKS access entry
# there, an impersonated service account granted in-cluster RBAC here -- but the
# semantic is one thing, so Sol passes the same variable to both roots and the
# provider decides how to realize it. That is capability parity rather than IAM
# cosplay, and it is why this is not a `gcp_provisioner_bootstrap_admin`.
#
# Default false: the privileged window exists only while Sol is installing, and a
# root applied directly by an operator never opens it.
variable "provisioner_bootstrap_admin" {
  description = "Temporarily grant the platform provisioner the in-cluster authority Sol needs to install privileged components. Sol opens this for the install window and closes it before Ready."
  type        = bool
  default     = false
}

variable "sql_deletion_protection" {
  description = "Enable both Terraform's destroy guard and Cloud SQL API deletion protection."
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
  description = "Provision GCS buckets + Workload Identity service accounts for durable Loki (OBS-006) and Thanos-backed Prometheus (OBS-007) storage. Pair with cli/platform/infra/base's observability_backend = \"self_hosted_durable\". Mirrors cli/platform/infra/aws's enable_durable_observability."
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

# ── Alerting (OBS-043) ──────────────────────────────────────────────────────
# Consumed by cli/platform/infra/base; declared here too so a target passing the
# alert_* contract through `sol cloud tf` does not fail on an undeclared
# variable in this layer. This layer ignores them.
variable "alert_receiver_type" {
  type    = string
  default = ""
}

variable "alert_receiver_url" {
  type    = string
  default = ""
}

variable "alert_owner" {
  type    = string
  default = ""
}

variable "alert_runbook_url" {
  type    = string
  default = ""
}
