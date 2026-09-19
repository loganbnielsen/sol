# cli/platform/infra/base-gcp — the GCP platform root
#
# The platform *definition* is `cli/platform/infra/base`; this root supplies what
# only a root can: the state backend, and therefore the backend type. Terraform
# fixes a backend's type in the root's own configuration -- `-backend-config`
# sets attributes, never the type -- so the S3 backend `base` declares cannot be
# the GCS one a GCP target needs. `base`'s own `terraform` block is ignored when
# `base` is called as a module (Terraform says so and continues), which is what
# lets one platform definition serve both roots.
#
# Every variable below is a pass-through, including ones a provider does not use
# yet: this root exists so the shared definition is reachable from GCP, not to
# narrow it. `internal/ci/check_platform_root_wrapper.sh` fails if `base` gains a
# variable this root does not mirror.
#
# Not yet qualified on GCP: the shared definition's cert-manager ClusterIssuers
# are hard-wired to the Route 53 DNS-01 solver, so a GCP install cannot yet issue
# a certificate. That is a separate change; the state backend is this one.

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

variable "create_storage_class" {
  description = "Create Sol's own default StorageClass. Always false on GCP and only meaningful there as an input a shared tooling invocation may still pass: GKE ships `standard-rwo` as the cluster default, so the platform adopts it and creating a second default class would leave the cluster with two."
  type        = bool
  default     = false
}

variable "storage_class_name" {
  description = "Name of the default StorageClass the platform's durable volumes bind to. On GCP that is GKE's adopted `standard-rwo`; the definition creates its own only on AWS."
  type        = string
  default     = "standard-rwo"
}

variable "cloud_provider" {
  description = "Cloud provider for provider-specific Kubernetes integrations. This root is the GCP one, so it defaults to gcp; `sol cloud` always sets it explicitly."
  type        = string
  default     = "gcp"
  validation {
    condition     = contains(["aws", "gcp"], var.cloud_provider)
    error_message = "cloud_provider must be one of: aws, gcp."
  }
}

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

variable "letsencrypt_email" {
  description = "Email address for Let's Encrypt certificate notifications"
  type        = string
}
