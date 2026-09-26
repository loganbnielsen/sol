# platform/cloud/gcp/platform — the GCP platform root. See variables.tf for why
# this root exists at all, and which parts of the shared definition are not yet
# GCP-shaped.
#
# The shared module declares no backend (REFAC-100): a backend belongs to a root,
# and supplying GCP's is the whole reason this file exists.

terraform {
  required_version = ">= 1.6"

  # GCS, with GCS's native state locking -- there is no lock resource to name,
  # which is why a GCP target declares no state_lock_table. `sol cloud` supplies
  # bucket= and prefix=sol/<target>/platform.tfstate from the target's declared
  # state bucket.
  backend "gcs" {}

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
  }
}

# The shared platform definition. Providers are inherited from this root, so the
# same KUBE_CONFIG_PATH/KUBE_CONFIG_PATHS contract `sol cloud` establishes for the
# ephemeral provisioner kubeconfig applies unchanged.
module "platform" {
  source = "../../modules/platform"

  base_domain                          = var.base_domain
  cluster_issuer                       = var.cluster_issuer
  ingress_service_type                 = var.ingress_service_type
  create_storage_class                 = var.create_storage_class
  storage_class_name                   = var.storage_class_name
  cloud_provider                       = var.cloud_provider
  redpanda_replicas                    = var.redpanda_replicas
  redpanda_cpu_cores                   = var.redpanda_cpu_cores
  redpanda_memory                      = var.redpanda_memory
  redpanda_persistent_storage          = var.redpanda_persistent_storage
  install_postgresql                   = var.install_postgresql
  gcp_provisioner_service_account      = var.gcp_provisioner_service_account
  postgres_password                    = var.postgres_password
  postgres_persistent_storage          = var.postgres_persistent_storage
  grafana_admin_password               = var.grafana_admin_password
  loki_persistent_storage              = var.loki_persistent_storage
  prometheus_persistent_storage        = var.prometheus_persistent_storage
  observability_backend                = var.observability_backend
  external_loki_url                    = var.external_loki_url
  external_loki_username               = var.external_loki_username
  external_loki_password               = var.external_loki_password
  external_prometheus_remote_write_url = var.external_prometheus_remote_write_url
  external_prometheus_username         = var.external_prometheus_username
  external_prometheus_password         = var.external_prometheus_password
  loki_gcs_bucket                      = var.loki_gcs_bucket
  loki_workload_identity_sa_email      = var.loki_workload_identity_sa_email
  thanos_gcs_bucket                    = var.thanos_gcs_bucket
  thanos_workload_identity_sa_email    = var.thanos_workload_identity_sa_email
  prometheus_raw_retention_days        = var.prometheus_raw_retention_days
  thanos_retention_5m_days             = var.thanos_retention_5m_days
  thanos_retention_1h_days             = var.thanos_retention_1h_days
  managed_resource_dashboards          = var.managed_resource_dashboards
  alert_receiver_type                  = var.alert_receiver_type
  alert_receiver_url                   = var.alert_receiver_url
  alert_owner                          = var.alert_owner
  alert_runbook_url                    = var.alert_runbook_url
  letsencrypt_email                    = var.letsencrypt_email
}
