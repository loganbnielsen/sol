# platform/infra/gcp — GCP cluster provisioning for Sol workspaces
#
# Provisions:
#   VPC                — custom VPC with secondary ranges for GKE pods/services
#   GKE                — Autopilot cluster (no node management, scales to zero)
#   Artifact Registry  — container image registry (one per workspace)
#   Cloud SQL          — managed PostgreSQL (replaces in-cluster postgres)
#   Cloud DNS zone     — base domain for Ingress / cert-manager
#
# After apply: run platform/infra/base/ to install platform components.
#
# Usage:
#   terraform init
#   terraform apply -var="project_id=my-project" -var="cluster_name=acme-prod" \
#     -var="base_domain=acme.com"

terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.25"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }

  # Uncomment to store state in GCS (recommended for teams):
  # backend "gcs" {
  #   bucket = "my-terraform-state"
  #   prefix = "sol/prod"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ── VPC ───────────────────────────────────────────────────────────────────── #

resource "google_compute_network" "main" {
  name                    = var.cluster_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  name          = "${var.cluster_name}-nodes"
  ip_cidr_range = var.nodes_cidr
  region        = var.region
  network       = google_compute_network.main.id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  private_ip_google_access = true
}

resource "google_compute_router" "main" {
  name    = "${var.cluster_name}-router"
  network = google_compute_network.main.id
  region  = var.region
}

resource "google_compute_router_nat" "main" {
  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.main.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# ── GKE Autopilot ─────────────────────────────────────────────────────────── #

resource "google_container_cluster" "main" {
  name     = var.cluster_name
  location = var.region

  # Autopilot: Google manages nodes, scaling, and security hardening
  enable_autopilot = true

  network    = google_compute_network.main.id
  subnetwork = google_compute_subnetwork.main.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Private cluster: nodes have no public IPs
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
  }

  release_channel {
    channel = "REGULAR"
  }
}

# ── Artifact Registry ─────────────────────────────────────────────────────── #

resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = var.cluster_name
  format        = "DOCKER"
  description   = "Container images for ${var.cluster_name} Sol workspace"
}

# Grant GKE SA read access to pull images
resource "google_artifact_registry_repository_iam_member" "gke_pull" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_container_cluster.main.node_config[0].service_account}"
}

# ── Cloud SQL PostgreSQL ──────────────────────────────────────────────────── #

resource "google_sql_database_instance" "postgres" {
  name             = "${var.cluster_name}-postgres"
  database_version = "POSTGRES_16"
  region           = var.region
  deletion_protection = var.sql_deletion_protection

  settings {
    tier              = var.sql_tier
    availability_type = var.sql_high_availability ? "REGIONAL" : "ZONAL"
    disk_autoresize   = true
    disk_size         = var.sql_disk_gb

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.main.id
    }

    insights_config {
      query_insights_enabled = true
    }
  }

  depends_on = [google_service_networking_connection.sql]
}

resource "google_sql_database" "app" {
  name     = "app"
  instance = google_sql_database_instance.postgres.name
}

resource "google_sql_user" "postgres" {
  name     = "postgres"
  instance = google_sql_database_instance.postgres.name
  password = var.db_password
}

# Private service connection for Cloud SQL
resource "google_compute_global_address" "sql_peering" {
  name          = "${var.cluster_name}-sql-peering"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "sql" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.sql_peering.name]
}

# ── Cloud DNS ─────────────────────────────────────────────────────────────── #

resource "google_dns_managed_zone" "main" {
  count       = var.create_dns_zone ? 1 : 0
  name        = replace(var.base_domain, ".", "-")
  dns_name    = "${var.base_domain}."
  description = "Sol workspace zone for ${var.cluster_name}"
}
