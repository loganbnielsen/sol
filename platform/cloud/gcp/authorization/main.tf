terraform {
  required_version = ">= 1.6"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  secret_prefix = "sol-${var.environment}-"
  role_id       = "sol_${replace(var.environment, "-", "_")}_authorization"
}

resource "google_service_account" "reconciler" {
  account_id   = "sol-${var.environment}-authorization"
  display_name = "Sol ${var.environment} authorization reconciler"
  description  = "Fenced reconciler for ${var.environment}'s Sol secret grants (DEC-062)."
}

resource "google_project_iam_custom_role" "authorization" {
  role_id     = local.role_id
  title       = "Sol ${var.environment} authorization reconciler"
  description = "Resource-scoped secret grant authority for ${var.environment}; it creates no service accounts and mutates no project IAM."
  permissions = [
    "secretmanager.secrets.get",
    "secretmanager.secrets.list",
    "secretmanager.secrets.getIamPolicy",
    "secretmanager.secrets.setIamPolicy",
    "secretmanager.versions.access",
  ]
}

resource "google_project_iam_member" "reconciler_authorization" {
  project = var.project_id
  role    = google_project_iam_custom_role.authorization.id
  member  = "serviceAccount:${google_service_account.reconciler.email}"

  condition {
    title       = "sol-managed-secrets-only"
    description = "The reconciler may set grants only on secrets this environment owns."
    expression  = "resource.name.startsWith(\"projects/${var.project_id}/secrets/${local.secret_prefix}\")"
  }
}

resource "google_service_account_iam_member" "reconciler_impersonation" {
  service_account_id = google_service_account.reconciler.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = var.reconciler_trust_principal
}
