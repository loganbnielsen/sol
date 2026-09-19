# cli/platform/infra/gcp — GCP cluster provisioning for Sol workspaces
#
# Provisions:
#   VPC                — custom VPC with secondary ranges for GKE pods/services
#   GKE                — Autopilot cluster (no node management, scales to zero)
#   Artifact Registry  — container image registry (one per workspace)
#   Cloud SQL          — managed PostgreSQL (replaces in-cluster postgres)
#   Cloud DNS zone     — base domain for Ingress / cert-manager
#
# After apply: run cli/platform/infra/base/ to install platform components.
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

  # GCS, with GCS's native state locking. `sol cloud` supplies bucket= and
  # prefix=sol/<target>/cloud.tfstate from the target's declared state bucket;
  # there is no lock resource to name, which is why a GCP target declares no
  # state_lock_table.
  backend "gcs" {}
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

  # The provider defaults this to true, so a root that never mentions it still
  # produces a cluster Sol cannot destroy: live attempt 1 lifted Cloud SQL's guard,
  # deleted everything else, and was then refused with "Cannot destroy cluster
  # because deletion_protection is set to true". That is ADR 0004's invariant
  # reached through a provider *default* rather than through `prevent_destroy`,
  # which is why a search for suspicious configuration found nothing -- there was
  # no attribute to find, only an attribute's absence. Routing it through a
  # variable is what makes the default explicit, and the Destroy policy is what
  # lifts it.
  deletion_protection = var.gke_deletion_protection

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

# Autopilot reports its node service account as the literal shorthand "default",
# and the IAM API rejects `serviceAccount:default` ("Error 400: Invalid service
# account (default)") -- which is where live attempt 1's apply died, after the
# cluster and the database had already been created. "default" means the project's
# Compute Engine default service account, so that is what it is resolved to.
data "google_compute_default_service_account" "default" {
  project = var.project_id
}

locals {
  gke_node_service_account = (
    google_container_cluster.main.node_config[0].service_account == "default"
    ? data.google_compute_default_service_account.default.email
    : google_container_cluster.main.node_config[0].service_account
  )
}

# Grant GKE SA read access to pull images
resource "google_artifact_registry_repository_iam_member" "gke_pull" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${local.gke_node_service_account}"
}

# ── Cloud SQL PostgreSQL ──────────────────────────────────────────────────── #

resource "google_sql_database_instance" "postgres" {
  name                = "${var.cluster_name}-postgres"
  database_version    = "POSTGRES_16"
  region              = var.region
  deletion_protection = var.sql_deletion_protection

  settings {
    tier                        = var.sql_tier
    availability_type           = var.sql_high_availability ? "REGIONAL" : "ZONAL"
    deletion_protection_enabled = var.sql_deletion_protection
    disk_autoresize             = true
    disk_size                   = var.sql_disk_gb

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

# Attempt 1 could not delete this peering at all, and Attempt 2 showed the obvious
# reading of that -- "the graph is right, so what is missing must be a wait" -- to be
# wrong. Five minutes of explicit waiting (`time_sleep`) did not help, and neither did
# twenty minutes of manual retries: GCP keeps reporting that a producer still uses the
# connection, and what actually releases it is deleting the *network*, which this root
# owns and the same destroy deletes.
#
# So the connection is abandoned rather than deleted. Asking GCP to delete an object it
# will not delete while a producer is registered is what failed; the timing was never
# the problem, and raising a sleep to a larger guessed number would have been a change
# that only looks like a fix.
#
# What this gives up is Terraform's own confirmation that the peering is gone, which is
# why `verify_gcp_destroy` asks the provider for the peering *and* the network after the
# destroy instead of trusting this apply's exit status. Abandonment is only defensible
# against a check that can see the thing that was abandoned.
resource "google_service_networking_connection" "sql" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.sql_peering.name]

  deletion_policy = "ABANDON"
}

# ── The platform provisioner ──────────────────────────────────────────────── #
#
# The identity that installs and maintains the platform. Live attempt 1 installed
# as the operator's own Owner account, which the review named correctly: that is
# not an authority model, it is a coincidence of who ran the command.
#
# The invariant to preserve is the one AWS's bootstrap window preserves:
# *the authority required to install privileged platform components exists only
# during the lifecycle stage that requires it; steady-state identities do not
# retain it.* GCP realizes that differently, and the difference is real rather
# than cosmetic:
#
#   * the identity is a Google service account, not an IAM role, so callers
#     impersonate it and Google issues short-lived tokens -- there is never a
#     static key in a file (the same reason the Loki/Thanos identities below are
#     service accounts rather than keys);
#   * GKE authorization is RBAC-first with Google IAM as a fallback. The custom
#     IAM role below therefore contains only cluster discovery, credential
#     retrieval, and control-plane connection permissions -- never Kubernetes
#     object permissions. Scoped in-cluster authority comes from RBAC;
#   * the install window's privilege is therefore a Kubernetes RBAC binding,
#     created for that window and removed at the end of it, because GKE has no
#     access-entry equivalent that maps a cloud identity to in-cluster rights.
#
# The steady-state binding to the shared definition's provisioner ClusterRole is
# created by the platform root (where that ClusterRole lives), not here.
# The install window's privilege. It is created *here*, in the cloud root, and
# that placement is the whole point rather than a convenience:
#
#   * the platform applies run as the provisioner, which by construction has no
#     in-cluster rights until the platform root creates them -- so a binding that
#     grants those rights cannot be created by the apply that needs them. The
#     escalation has to be created by a caller that already has authority, and the
#     cloud root is applied with the operator's credentials.
#   * this is exactly where AWS puts it: an EKS access entry associated by the
#     cloud apply, opened before the first platform apply and associated away
#     afterwards. Same object lifecycle, different object.
#
# `provisioner_bootstrap_admin` is therefore declared by both provider *cloud*
# roots, and Sol opens and closes it with the same variable on both.
data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.main.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.main.master_auth[0].cluster_ca_certificate)
}

resource "kubernetes_cluster_role_binding" "provisioner_bootstrap_admin" {
  count = var.provisioner_bootstrap_admin ? 1 : 0

  metadata { name = "sol-platform-provisioner-bootstrap-admin" }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "User"
    name      = google_service_account.provisioner.email
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "google_service_account" "provisioner" {
  account_id   = "${var.cluster_name}-provisioner"
  display_name = "Sol platform provisioner for ${var.cluster_name}"
  project      = var.project_id
}

# The cloud-side prerequisite, and only that: enough to obtain credentials for and
# read this cluster. Deliberately not `roles/container.admin` -- the authority to
# *change* the cluster is not the authority to install into it.
#
# This is not the provisioner's install authority, and the two are auditable
# separately on purpose:
#
#   can this identity do too much in GCP?  -> IAM, answered by this binding
#   can this identity do too much in the cluster? -> Kubernetes RBAC, answered by
#       the ClusterRoles the platform definition binds it to
#
# A single answer covering both is how "the provisioner needs to install charts"
# becomes "the provisioner is an administrator".
resource "google_project_iam_custom_role" "provisioner_cluster_access" {
  project     = var.project_id
  role_id     = "sol_${replace(var.cluster_name, "-", "_")}_cluster_access"
  title       = "Sol provisioner cluster access"
  description = "Discover and obtain credentials for GKE clusters; Kubernetes object authority is supplied only by RBAC."
  permissions = [
    "container.clusters.get",
    "container.clusters.list",
    "container.clusters.getCredentials",
    "container.clusters.connect",
  ]
}

resource "google_project_iam_member" "provisioner_cluster_access" {
  project = var.project_id
  role    = google_project_iam_custom_role.provisioner_cluster_access.name
  member  = "serviceAccount:${google_service_account.provisioner.email}"
}

# Attempt 2's first finding: creating the identity is not the same as letting
# anyone *use* it. Sol reaches the cluster by impersonating the provisioner, and
# impersonation needs `iam.serviceAccounts.getAccessToken` on that identity --
# which nothing granted, so the first attempt to enter the window failed with
# "Failed to impersonate ... Permission 'iam.serviceAccounts.getAccessToken'
# denied" and never reached Kubernetes at all.
#
# This is the GCP half of what `sts:AssumeRole` covers on AWS, and the shape is
# deliberately narrow in two directions at once:
#
#   * the role is `roles/iam.serviceAccountTokenCreator` on *this one* service
#     account, not a project-level role -- the authority to act as the provisioner
#     is the authority to act as the provisioner, and nothing else;
#   * the members are named by the target (`provisioner_impersonator`), not
#     inferred from whoever happens to run Sol. Inferring it would recreate exactly
#     the ambient-authority escape hatch this whole change exists to remove: "no
#     caller declared" must mean "no impersonation", not "grant the caller".
#
# Note what this is *not*: it is not the install authority. It is the authority to
# enter the window. What the provisioner may then do in the cluster is decided by
# the ClusterRoles the platform definition binds it to, and the temporary
# cluster-admin is the window's own object below.
resource "google_service_account_iam_member" "provisioner_impersonators" {
  for_each = toset(var.provisioner_impersonators)

  service_account_id = google_service_account.provisioner.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = each.value
}

# ── Cloud DNS ─────────────────────────────────────────────────────────────── #

resource "google_dns_managed_zone" "main" {
  count       = var.create_dns_zone ? 1 : 0
  name        = replace(var.base_domain, ".", "-")
  dns_name    = "${var.base_domain}."
  description = "Sol workspace zone for ${var.cluster_name}"
}

# ── Durable observability storage (OBS-006 logs, OBS-007 metrics) ─────────── #
#
# GCP side of cli/platform/infra/aws's S3+IRSA pair (INFRA-003) -- GCS buckets +
# Workload Identity service accounts, mirroring aws/'s shape and output
# names 1:1 (loki_s3_bucket -> loki_gcs_bucket, loki_irsa_arn ->
# loki_workload_identity_sa_email, etc.) so cli/platform/infra/base can be wired
# up to consume either provider's outputs through the same kind of plain
# variables it already uses for AWS. GKE Autopilot clusters (module.main
# above) have Workload Identity enabled by default -- no cluster-level
# opt-in needed, unlike standard GKE.
#
# Layer 1 only: this module does not wire these outputs into
# cli/platform/infra/base, and does not lift base's `cloud_provider == "aws"`
# gate on observability_backend = "self_hosted_durable" (see
# cli/platform/infra/base/main.tf's observability_backend_validation). That
# gate also controls provider-specific Helm values baked into
# cli/platform/components/loki/values-durable.json (storage.type = "s3",
# object_store = "s3") -- wiring GCS through there needs a live GCP cluster
# to validate against and is real, separate follow-up scope, not bundled
# into this ticket's Layer 1 module per its own "no abstraction ahead of a
# concrete second implementation" scope note.

resource "google_storage_bucket" "loki" {
  count                       = var.enable_durable_observability ? 1 : 0
  name                        = "${var.cluster_name}-loki-logs"
  location                    = var.region
  project                     = var.project_id
  uniform_bucket_level_access = true
  force_destroy               = true

  lifecycle_rule {
    condition {
      age = var.loki_retention_days
    }
    action {
      type = "Delete"
    }
  }
  # INFRA-037: same invariant as AWS (ADR 0004) -- these buckets are populated by
  # running the platform, so [force_destroy = false] together with
  # [prevent_destroy] left a durable-observability target undeletable through
  # `sol cloud destroy`.
}

resource "google_service_account" "loki" {
  count        = var.enable_durable_observability ? 1 : 0
  project      = var.project_id
  account_id   = "${var.cluster_name}-loki"
  display_name = "Loki durable storage (Workload Identity) for ${var.cluster_name}"
}

resource "google_storage_bucket_iam_member" "loki" {
  count  = var.enable_durable_observability ? 1 : 0
  bucket = google_storage_bucket.loki[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.loki[0].email}"
}

# Binds the GCP service account to the "monitoring/loki" Kubernetes service
# account via Workload Identity -- same single namespace:service-account
# pair as aws/'s module.loki_irsa oidc_providers binding.
resource "google_service_account_iam_member" "loki_workload_identity" {
  count              = var.enable_durable_observability ? 1 : 0
  service_account_id = google_service_account.loki[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[monitoring/loki]"
}

resource "google_storage_bucket" "thanos" {
  count                       = var.enable_durable_observability ? 1 : 0
  name                        = "${var.cluster_name}-thanos-metrics"
  location                    = var.region
  project                     = var.project_id
  uniform_bucket_level_access = true
  force_destroy               = true
  # INFRA-037: same invariant as AWS (ADR 0004) -- these buckets are populated by
  # running the platform, so [force_destroy = false] together with
  # [prevent_destroy] left a durable-observability target undeletable through
  # `sol cloud destroy`.
}

resource "google_service_account" "thanos" {
  count        = var.enable_durable_observability ? 1 : 0
  project      = var.project_id
  account_id   = "${var.cluster_name}-thanos"
  display_name = "Thanos durable storage (Workload Identity) for ${var.cluster_name}"
}

resource "google_storage_bucket_iam_member" "thanos" {
  count  = var.enable_durable_observability ? 1 : 0
  bucket = google_storage_bucket.thanos[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.thanos[0].email}"
}

# aws/'s module.thanos_irsa binds one IAM role to three Kubernetes service
# accounts in a single oidc_providers block; Workload Identity binds one
# GCP SA to one Kubernetes SA per google_service_account_iam_member, so the
# same three-way binding takes a for_each here instead.
resource "google_service_account_iam_member" "thanos_workload_identity" {
  for_each = var.enable_durable_observability ? toset([
    "monitoring/prometheus-server",
    "monitoring/thanos-storegateway",
    "monitoring/thanos-compactor",
  ]) : []

  service_account_id = google_service_account.thanos[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${each.value}]"
}
