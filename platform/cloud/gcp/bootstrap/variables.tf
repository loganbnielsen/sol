variable "project_id" {
  description = "GCP project that owns the Terraform state bucket."
  type        = string
}

variable "region" {
  description = "GCP region, used as the bucket's location."
  type        = string
}

variable "state_bucket" {
  description = "Globally-unique GCS bucket name for the versioned, access-controlled Terraform state."
  type        = string
}

variable "manage_dns_zone" {
  description = "Own the delegated qualification DNS zone from this durable root. Off by default: a project that has not delegated a zone has none to own."
  type        = bool
  default     = false
}

variable "base_domain" {
  description = "The delegated qualification name (e.g. qual-gcp.sol-fab.dev). Required when manage_dns_zone is true."
  type        = string
  default     = ""
}
