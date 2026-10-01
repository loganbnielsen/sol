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


resource "google_dns_record_set" "delegation" {
  count = var.manage_dns_zone && var.parent_zone_id != "" ? 1 : 0

  managed_zone = var.parent_zone_id
  name         = google_dns_managed_zone.qualification[0].dns_name
  type         = "NS"
  ttl          = 172800
  rrdatas      = google_dns_managed_zone.qualification[0].name_servers
}

resource "google_storage_bucket" "state" {
  name                        = var.state_bucket
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  labels = {
    "sol-role" = "terraform-state"
  }

}

resource "google_dns_managed_zone" "qualification" {
  count       = var.manage_dns_zone ? 1 : 0
  name        = replace(var.base_domain, ".", "-")
  dns_name    = "${var.base_domain}."
  description = var.base_domain == "" ? "" : "Durable Sol qualification DNS zone for ${var.base_domain}"
}
