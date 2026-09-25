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

variable "sql_deletion_protection" {
  description = "Enable both Terraform's destroy guard and Cloud SQL API deletion protection."
  type        = bool
  default     = true
}

# The identity allowed to enter this target's install window, declared by the target
# (`provisioner_impersonator`). Naming the caller is a requirement rather than a
# convenience: an empty list means no impersonation grant at all, because inferring
# the caller from the running process is the ambient-authority escape hatch this
# model exists to close.
variable "provisioner_impersonators" {
  description = "IAM members (for example `user:ops@example.com`, or a service account) allowed to impersonate the platform provisioner and enter the install window. Each receives roles/iam.serviceAccountTokenCreator on that one identity."
  type        = list(string)
  default     = []
}

# The install window itself. Both provider roots declare it -- the object differs (an
# EKS access entry on AWS, an in-cluster ClusterRoleBinding here) -- and Sol opens it
# for the applies that install and closes it before reporting one. On GCP the binding
# is created here, in the cloud root, because the platform applies run *as* the
# provisioner and so cannot be the thing that grants the provisioner its authority.
variable "provisioner_bootstrap_admin" {
  description = "Temporarily grant the platform provisioner the in-cluster authority the install needs. Sol opens this for the install window and closes it before Ready."
  type        = bool
  default     = false
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

# ── Alerting (OBS-043) ──────────────────────────────────────────────────────
# Consumed by platform/infra/base; declared here too so a target passing the
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

# INFRA-077 / FND-0057: Cloud Storage soft delete, declared rather than defaulted.
# GCS retains soft-deleted objects (and a deleted bucket) for the policy's duration and
# bills them at storage rates. Sol routes 0 for a `destroy_retention: none` target, so
# its destroy leaves nothing billable behind, and an explicit 7 days otherwise.
variable "gcs_soft_delete_retention_seconds" {
  description = "Soft-delete retention for the observability buckets, in seconds: 0 (disabled) or 7-90 days."
  type        = number
  default     = 604800

  validation {
    condition     = var.gcs_soft_delete_retention_seconds == 0 || (var.gcs_soft_delete_retention_seconds >= 604800 && var.gcs_soft_delete_retention_seconds <= 7776000)
    error_message = "gcs_soft_delete_retention_seconds must be 0 (disabled) or between 604800 (7 days) and 7776000 (90 days)."
  }
}

