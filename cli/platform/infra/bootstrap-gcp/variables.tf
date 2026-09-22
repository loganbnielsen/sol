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
