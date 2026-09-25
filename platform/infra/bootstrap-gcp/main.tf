# This root's OWN state must be durable for the same reason its resources are: it owns the
# delegated DNS zone, and an owner whose state lives in a working directory is one
# `rm -rf` from unowning it. The bucket is supplied at init rather than declared here,
# because a configuration cannot create the backend that stores its own state:
#
#   terraform init \
#     -backend-config=bucket=<state_bucket> -backend-config=prefix=bootstrap/gcp
#   terraform plan -var="project_id=..." -var="region=..." \
#     -var="state_bucket=<state_bucket>" -var="manage_dns_zone=true" \
#     -var="base_domain=qual-gcp.sol-fab.dev"
#
# The first run against a project has to create the bucket before it can store state in
# it, so the very first init is `-backend=false` (local state), the bucket is applied, and
# the state is then migrated in with `-migrate-state`. That recursion is the one part of
# the durable/ disposable split a bootstrap root cannot escape; everything after it is
# ordinary.
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


# ── The remote state backend, GCP side ───────────────────────────────────────
#
# The provider-equivalent of platform/infra/bootstrap (AUDIT-072). Sol
# provisions this by default; an operator may bring an equivalent backend
# (versioned, access-controlled) and declare it on the target instead. This root
# is separate from platform/infra/gcp because a Terraform configuration
# cannot create its own backend: run this once, record the bucket as
# `state_bucket` on the target, and Sol derives the rest.
#
# Two provider differences from the AWS root, both deliberate:
#
#   * There is no lock resource. GCS serializes state itself, and
#     Sol_cli_cloud_lifecycle.backend_config sends a GCP target only
#     `bucket=` and `prefix=` — no DynamoDB analogue exists to name. (A GCP
#     target that declares `state_lock_table` is not wrong; the field simply is
#     not what serializes applies there.)
#   * Sol builds the backend body, not this root: for GCP it passes
#     `bucket=<bucket>` and `prefix=sol/<cloud|platform>/<target>.tfstate`. So the
#     only thing an operator records is the bucket name.
#
# LIFETIME — this bucket is a durable prerequisite, not target infrastructure
# (FND-0028, DEC-043). A target destroy must not remove it, and the qualification
# harness verifies it SURVIVES teardown rather than assuming it, exactly as it does
# for the delegated Cloud DNS zone. `force_destroy` therefore stays false: an
# accidental destroy fails rather than discarding the only copy of the state that
# describes everything else.
#
# Not mirrored here, and this is a boundary rather than an omission: the AWS root
# also generates the four identity policy contracts. GCP's identity model is not
# policy-document shaped — a caller impersonates a service account with short-lived
# credentials, the cloud root already outputs `provisioner_service_account`, and
# Sol_cli_cloud_lifecycle.governs deliberately keeps identity out of the target for
# that provider. Whether bootstrap should own identity enablement for either
# provider is DEC-043's question, not something to invent here.

# ── AUDIT-072: the conformant remote state backend ──────────────────────────

resource "google_storage_bucket" "state" {
  name                        = var.state_bucket
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  # Versioning is the property that makes a state backend recoverable: a bad
  # apply can be rolled back to the previous state object rather than rebuilt.
  versioning {
    enabled = true
  }

  labels = {
    "sol-role" = "terraform-state"
  }

  # No encryption resource is needed: GCS encrypts every object at rest with
  # Google-managed keys by default, where S3 required an explicit SSE resource.
  # A customer-managed key would be a deliberate choice, not a conformance default.
}

# ── The delegated qualification DNS zone (DEC-043) ──────────────────────────
#
# A durable prerequisite, not target infrastructure: the registrar NS records that make
# it work live outside every provider API Sol can call, so a target destroy that removed
# the zone would silently leave them pointing at nothing -- and a recreate assigns
# *different* nameservers. Attempt 5 demonstrated the conflict empirically: the zone was
# created by the disposable cloud root, and removing the target that owns it meant either
# destroying the delegation or removing the zone from state by hand.
#
# So the zone is owned HERE, alongside the state bucket, by the root whose lifetime is
# the account rather than the target. The target's cloud root keeps its create_dns_zone
# switch for providers that have not made this migration, but for a qualified GCP target
# it must be false -- two roots must never manage one zone.
#
# Adopting an existing zone is an import, never a recreate:
#
#   terraform import \
#     -var="manage_dns_zone=true" -var="base_domain=qual-gcp.sol-fab.dev" \
#     'google_dns_managed_zone.qualification[0]' \
#     projects/sol-qualification/managedZones/qual-gcp-sol-fab-dev
#
# The import preserves the assigned nameservers, which is the whole point: the delegation
# pasted at the registrar keeps working. Note what the import does NOT preserve: this
# root's description differs from the one the cloud root wrote, so adopting a zone
# produces a metadata-only update. The nameservers -- the part the delegation depends on
# -- are untouched, and are also what the output below exists to read.
#
resource "google_dns_managed_zone" "qualification" {
  count       = var.manage_dns_zone ? 1 : 0
  name        = replace(var.base_domain, ".", "-")
  dns_name    = "${var.base_domain}."
  description = var.base_domain == "" ? "" : "Durable Sol qualification DNS zone for ${var.base_domain}"
}
