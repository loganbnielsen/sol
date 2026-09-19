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

# The GKE provider's own guard, and it is ON by default -- so a target that never
# mentions it still cannot be destroyed (live attempt 1: "Cannot destroy cluster
# because deletion_protection is set to true", after Cloud SQL had already been
# lifted and everything else deleted). It is the same defect class ADR 0004 names,
# expressed through a provider default instead of `prevent_destroy`, which is why
# the invariant has to be asserted over what a root *ends up with* rather than
# over the attributes it happens to spell out.
#
# Default true, so a destroy driven directly against Terraform fails rather than
# deleting a cluster by surprise; `sol cloud destroy`'s Destroy policy sets it
# false for the teardown, exactly as it does for Cloud SQL.
variable "gke_deletion_protection" {
  description = "Enable the GKE provider's deletion protection on the cluster. Default true (a direct destroy fails rather than deleting a cluster); `sol cloud destroy` sets it false for the Destroy phase."
  type        = bool
  default     = true
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
