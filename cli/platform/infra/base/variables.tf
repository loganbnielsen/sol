variable "base_domain" {
  description = "Base domain for Ingress resources, e.g. mycompany.com. Subdomains argocd.*, grafana.* are created."
  type        = string
}

variable "cluster_issuer" {
  description = "cert-manager ClusterIssuer name for TLS certificates."
  type        = string
  default     = "letsencrypt-prod"
}

variable "ingress_service_type" {
  description = "Kubernetes Service type for the ingress-nginx controller. Use LoadBalancer for cloud clusters, NodePort for k3d/local."
  type        = string
  default     = "LoadBalancer"
}

# HARDEN-002 run 2, finding 7: the qualified substrate provided no storage, so a
# persistent Redpanda (the profile's RF>=3 durability requirement) and every
# admitted workload volume stayed Pending. The driver is the cloud substrate's
# job (cli/platform/infra/aws installs the EBS CSI addon and its scoped IRSA
# role); the StorageClass is the platform substrate's, because it is a cluster
# object.
#
# This is platform storage, not an application workload volume declaration: it
# makes persistence physically possible without changing what a workload is
# allowed to declare, and it does not interact with the `single`-tier
# restriction DEC-026 §3 puts on workload-declared volumes.
variable "create_storage_class" {
  description = "Create the default StorageClass for the platform (AWS only; the EBS CSI driver must be installed)."
  type        = bool
  default     = true
}

variable "storage_class_name" {
  description = "Name of the default StorageClass this module creates."
  type        = string
  default     = "gp3"
}

variable "cloud_provider" {
  description = "Cloud provider for provider-specific Kubernetes integrations."
  type        = string
  default     = "aws"
  validation {
    condition     = contains(["aws", "gcp"], var.cloud_provider)
    error_message = "cloud_provider must be one of: aws, gcp."
  }
}

# Redpanda
variable "redpanda_replicas" {
  description = "Number of Redpanda broker replicas."
  type        = number
  default     = 3
}

variable "redpanda_cpu_cores" {
  description = "CPU cores per Redpanda broker."
  type        = number
  default     = 2
}

variable "redpanda_memory" {
  description = "Memory limit per Redpanda broker (e.g. 4Gi)."
  type        = string
  default     = "4Gi"
}

variable "redpanda_persistent_storage" {
  description = "Enable persistent volumes for Redpanda. Disable for ephemeral dev clusters."
  type        = bool
  default     = true
}

# PostgreSQL (in-cluster)
variable "install_postgresql" {
  description = "Install in-cluster PostgreSQL. Set false when using RDS or Cloud SQL."
  type        = bool
  default     = false
}

variable "postgres_password" {
  description = "PostgreSQL admin password. Ignored when install_postgresql=false."
  type        = string
  default     = "dev"
  sensitive   = true
}

variable "postgres_persistent_storage" {
  description = "Enable persistent volumes for PostgreSQL."
  type        = bool
  default     = true
}

# Grafana
variable "grafana_admin_password" {
  description = "Grafana admin password."
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "loki_persistent_storage" {
  description = "Enable persistent volumes for Loki."
  type        = bool
  default     = true
}

variable "prometheus_persistent_storage" {
  description = "Enable persistent volumes for Prometheus."
  type        = bool
  default     = true
}

# ── Observability backend profile (OBS-005/006/007) ──────────────────────── #
#
# "local" is for dev/throwaway clusters. "external" points at infrastructure
# the user already has. "self_hosted_durable" is the production self-host path:
# Loki/Prometheus backed by S3 via cli/platform/infra/aws (AWS only for now).

variable "observability_backend" {
  description = <<-EOT
    Observability backend profile:
      local                — in-cluster Loki + Grafana + Prometheus (default).
      external             — point Alloy/Prometheus remote_write at a
                              user-supplied endpoint; skip installing local
                              Loki + Grafana (Prometheus still runs to scrape
                              and forward, with minimal local retention).
      self_hosted_durable — same in-cluster components as "local", but backed
                              by durable storage provisioned in
                              cli/platform/infra/aws (see OBS-006/OBS-007).
  EOT
  type        = string
  default     = "local"
  validation {
    condition     = contains(["local", "external", "self_hosted_durable"], var.observability_backend)
    error_message = "observability_backend must be one of: local, external, self_hosted_durable."
  }
}

variable "external_loki_url" {
  description = "Loki push URL for the \"external\" profile, e.g. https://logs-prod-000.grafana.net/loki/api/v1/push. Required when observability_backend = \"external\"."
  type        = string
  default     = ""
}

variable "external_loki_username" {
  description = "Basic auth username for external_loki_url (e.g. a Grafana Cloud tenant ID). Leave empty for an endpoint that doesn't require auth."
  type        = string
  default     = ""
}

variable "external_loki_password" {
  description = "Basic auth password/API key for external_loki_url."
  type        = string
  default     = ""
  sensitive   = true
}

variable "external_prometheus_remote_write_url" {
  description = "Prometheus remote_write URL for the \"external\" profile. Required when observability_backend = \"external\"."
  type        = string
  default     = ""
}

variable "external_prometheus_username" {
  description = "Basic auth username for external_prometheus_remote_write_url."
  type        = string
  default     = ""
}

variable "external_prometheus_password" {
  description = "Basic auth password/API key for external_prometheus_remote_write_url."
  type        = string
  default     = ""
  sensitive   = true
}

# ── self_hosted_durable (AWS only) — from cli/platform/infra/aws's outputs ──── #
# cli/platform/infra/aws and cli/platform/infra/base are separate Terraform states
# with no automatic remote-state link (same pattern already used for
# cert_manager_irsa_role_arn) — pass these by hand from `terraform output`.

variable "aws_region" {
  description = "AWS region the S3 buckets live in (self_hosted_durable profile)."
  type        = string
  default     = "us-east-1"
}

variable "loki_s3_bucket" {
  description = "S3 bucket for durable Loki storage. From cli/platform/infra/aws's loki_s3_bucket output."
  type        = string
  default     = ""
}

variable "loki_irsa_role_arn" {
  description = "IAM role ARN for Loki's S3 access. From cli/platform/infra/aws's loki_irsa_arn output."
  type        = string
  default     = ""
}

variable "thanos_s3_bucket" {
  description = "S3 bucket for durable Prometheus/Thanos storage. From cli/platform/infra/aws's thanos_s3_bucket output."
  type        = string
  default     = ""
}

variable "thanos_irsa_role_arn" {
  description = "IAM role ARN for Thanos S3 access. From cli/platform/infra/aws's thanos_irsa_arn output."
  type        = string
  default     = ""
}

# ── self_hosted_durable (GCP) — from cli/platform/infra/gcp's outputs ──────── #
# INFRA-005: GCP counterpart to the AWS block above. Same manual cross-state
# wiring (no automatic remote-state link between infra/gcp and infra/base).
# Workload Identity supplies credentials the same ambient way IRSA does on
# AWS -- no access keys ever flow through these variables or into Kubernetes
# config. Plumbing only: the precondition below still requires
# cloud_provider == "aws" for self_hosted_durable, so these variables are
# accepted and wired but the GCP path cannot actually be selected until a
# live GCP cluster validates it and that precondition is relaxed.

variable "loki_gcs_bucket" {
  description = "GCS bucket for durable Loki storage. From cli/platform/infra/gcp's loki_gcs_bucket output."
  type        = string
  default     = ""
}

variable "loki_workload_identity_sa_email" {
  description = "GCP service account email for Loki's GCS access (Workload Identity). From cli/platform/infra/gcp's loki_workload_identity_sa_email output."
  type        = string
  default     = ""
}

variable "thanos_gcs_bucket" {
  description = "GCS bucket for durable Prometheus/Thanos storage. From cli/platform/infra/gcp's thanos_gcs_bucket output."
  type        = string
  default     = ""
}

variable "thanos_workload_identity_sa_email" {
  description = "GCP service account email for Thanos's GCS access (Workload Identity). From cli/platform/infra/gcp's thanos_workload_identity_sa_email output."
  type        = string
  default     = ""
}

variable "prometheus_raw_retention_days" {
  description = "Retention in days for raw Prometheus samples in Thanos compactor."
  type        = number
  default     = 90
  validation {
    condition     = var.prometheus_raw_retention_days >= 1 && floor(var.prometheus_raw_retention_days) == var.prometheus_raw_retention_days
    error_message = "prometheus_raw_retention_days must be a whole number of days >= 1."
  }
}

variable "thanos_retention_5m_days" {
  description = "Retention in days for Thanos 5m downsampled blocks."
  type        = number
  default     = 90
  validation {
    condition     = var.thanos_retention_5m_days >= 1 && floor(var.thanos_retention_5m_days) == var.thanos_retention_5m_days
    error_message = "thanos_retention_5m_days must be a whole number of days >= 1."
  }
}

variable "thanos_retention_1h_days" {
  description = "Retention in days for Thanos 1h downsampled blocks."
  type        = number
  default     = 90
  validation {
    condition     = var.thanos_retention_1h_days >= 1 && floor(var.thanos_retention_1h_days) == var.thanos_retention_1h_days
    error_message = "thanos_retention_1h_days must be a whole number of days >= 1."
  }
}

# ── Managed resource dashboards (AWS only) — OBS-044 ──────────────────────── #
# From cli/platform/infra/aws's outputs, same manual cross-state wiring pattern
# as loki_s3_bucket/thanos_irsa_role_arn above -- no automatic remote-state
# link between these two states.

variable "grafana_irsa_role_arn" {
  description = "IAM role ARN for Grafana's CloudWatch read access (managed-resource dashboards, OBS-044). From cli/platform/infra/aws's grafana_irsa_arn output. Required when managed_resource_dashboards is non-empty and cloud_provider = \"aws\"."
  type        = string
  default     = ""
}

variable "managed_resource_dashboards" {
  description = <<-EOT
    Managed-resource dashboards to provision in Grafana (OBS-044): a map of
    resource name -> {resource_type, cloudwatch_namespace, dimension_name,
    dimension_value, metrics}. From cli/platform/infra/aws's
    managed_resource_dashboards output (e.g. {"postgres" = {resource_type =
    "rds", cloudwatch_namespace = "AWS/RDS", dimension_name =
    "DBInstanceIdentifier", dimension_value = "acme-prod-postgres", metrics =
    ["CPUUtilization", "DatabaseConnections", ...]}}). One Grafana dashboard
    is provisioned per distinct resource_type (not per entry) from a shared
    template -- adding a future resource of an already-represented type
    needs no new dashboard, only a new map entry.
  EOT
  type = map(object({
    resource_type        = string
    cloudwatch_namespace = string
    dimension_name       = string
    dimension_value      = string
    metrics              = list(string)
  }))
  default = {}
}

# ── Alerting (OBS-043) ──────────────────────────────────────────────────────
# The provider-neutral alert-delivery contract. A production target declares
# these in its target file; `sol deploy`'s preflight validates them and
# `sol alert test` sends a synthetic alert through the configured receiver.
# Apply base with the same values so the Alertmanager route matches what the
# target claims. Empty values keep the deliberate dev null receiver (OBS-040).

variable "alert_receiver_type" {
  description = "Alert receiver adapter. \"webhook\" is the maturity-A reference mechanism; empty keeps the dev null receiver."
  type        = string
  default     = ""
  validation {
    condition     = contains(["", "webhook"], var.alert_receiver_type)
    error_message = "alert_receiver_type must be \"\" or \"webhook\" (the qualified maturity-A receiver adapter)."
  }
}

variable "alert_receiver_url" {
  description = "Endpoint the Alertmanager route delivers to when alert_receiver_type is set. Never a secret Sol stores; keep routing credentials in the receiver URL out of committed files."
  type        = string
  default     = ""
}

variable "alert_owner" {
  description = "Accountable owner attached to every required maturity-A alert."
  type        = string
  default     = ""
}

variable "alert_runbook_url" {
  description = "First-response runbook linked from every required maturity-A alert."
  type        = string
  default     = ""
}
